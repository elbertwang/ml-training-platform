#!/usr/bin/env python3
"""Export Cloud Monitoring time series into BigQuery `mlobs_raw.metric_samples`.

Why this exists. Cloud Monitoring is the right place to *collect* infrastructure
signal and the wrong place to *analyse* it: you cannot join a metric to a job's
log lines, its ML Diagnostics events or its cost. This lands the handful of
series the model needs into BigQuery so they sit in the same timeline as
everything else.

Two of the metrics below matter more than they look:

  logging.googleapis.com/log_entry_count
      Free, per-container, and it captures log storms with no log scanning at
      all. On 2026-08-24 gcsfuse-sidecar containers peaked at 4.83M entries per
      hour per pod; detecting that from the logs themselves would have meant
      reading the WARNING tier, which is 75% of all volume in this project.

  tpu.googleapis.com/instance/interruption_count
      Carries interruption_type and interruption_reason, which is the only
      first-party way to separate "infrastructure reclaimed the node" from
      "the training job crashed".

Long/narrow schema on purpose: adding a metric is a config edit, not a schema
migration, and the model layer pivots what it needs in SQL.

Idempotency. Each run DELETEs the point_time range it is about to write before
loading it. Without that, running every 5 minutes with a 1-hour window would
write every point twelve times and fact_goodput would report twelve times the
real chip-hours and cost -- silently, with no error anywhere. Append-plus-
deduping-view was the alternative; delete-then-load keeps the raw table exact
and avoids a window function over a growing table on every read.
"""

import argparse
import datetime as dt
import http.client
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PROJECT = os.environ.get("MLOBS_PROJECT", "tpu-for-training")
DEFAULT_DATASET = os.environ.get("MLOBS_RAW_DATASET", "mlobs_raw")

# (metric_type, resource_type filter or None, alignment seconds, aligner)
# ALIGN_RATE/ALIGN_SUM for counters, ALIGN_MEAN for gauges.
# Only export what the *model* needs. Anything that is merely displayed is read
# live from Cloud Monitoring by Grafana instead -- Monitoring API requests are
# free, so copying a metric that nothing joins against buys nothing.
#
# A metric belongs here when it meets at least one of:
#   * it must join to job identity (dim_pod) -- Cloud Monitoring cannot join to
#     BigQuery, and goodput/cost are per-job by definition;
#   * it must survive at original resolution beyond Cloud Monitoring's
#     fine-grained window (6 weeks for kubernetes.io/*, after which everything
#     is downsampled to 10 minutes -- which would destroy 5-minute goodput
#     buckets on any quarter-scale trend);
#   * it has to sit in the same table as logs and events for the timeline.
#
# memory_used and duty_cycle were exported for a while and read by nothing; they
# are now displayed straight from Cloud Monitoring and no longer copied.
METRICS = [
    # ---- node-scoped accelerator metrics: the chip-level source of truth ----
    #
    # One series per physical chip, keyed on node_name and accelerator_id, and
    # emitted whether or not a pod is scheduled. That single property is what
    # the container-scoped equivalents cannot provide:
    #
    #   * they cover every chip the fleet has running, so the count of series IS
    #     the scheduled chip count -- 512 series across 128 nodes, exactly four
    #     per node at every point sampled over four months;
    #   * a chip nobody is using still reports, at 0%, instead of vanishing from
    #     the average. 36 chips on 9 nodes read exactly 0.00% while running no
    #     workload at all;
    #   * one chip yields one reading. The container metric attributes a chip to
    #     whichever container claims it, so a pod handover briefly produces two
    #     series for one piece of silicon.
    #
    # Where a chip carries a single container series the two scopes agree to the
    # decimal -- 180 chips compared, median difference 0.0000pp. They diverge
    # only across handovers, and there the node figure is the physical one.
    #
    # accelerator_id is <gce-instance-id>-<0..3> here, the same spelling the
    # container metrics use, so job attribution joins directly.
    #
    # These do NOT flow into fact_metric: that table exists to join metrics to
    # dim_pod by pod_name, and these carry a node instead. They are read from
    # mlobs_raw.metric_samples and joined to dim_node_pool by node name.
    ("kubernetes.io/node/accelerator/tensorcore_utilization",
     "k8s_node", 300, "ALIGN_MEAN"),
    ("kubernetes.io/node/accelerator/duty_cycle",
     "k8s_node", 300, "ALIGN_MEAN"),
    # Memory bandwidth is the missing third dimension. duty_cycle says the chip
    # was busy and tensorcore says how much arithmetic it issued; when the first
    # is high and the second low the work is stalled on something, and this is
    # what distinguishes memory-bound from communication-bound.
    ("kubernetes.io/node/accelerator/memory_bandwidth_utilization",
     "k8s_node", 300, "ALIGN_MEAN"),

    # goodput input; joins to dim_pod
    ("kubernetes.io/container/accelerator/tensorcore_utilization",
     "k8s_container", 300, "ALIGN_MEAN"),
    # The layer between "a pod is on the chip" and "the TensorCore is issuing
    # ops". duty_cycle is time-based -- percent of the sample period the
    # accelerator was actively processing -- while tensorcore_utilization is
    # throughput-based, ops performed over ops supported. A chip can therefore
    # be busy every second and still use a quarter of its arithmetic, and that
    # gap is a different kind of waste from an idle chip: measured live on
    # 2026-09-05, duty_cycle ran a median of 100.0 against tensorcore's 24.8.
    #
    # It was collected once before and dropped from this list; the orphaned rows
    # it left in metric_samples span 2026-08-23 20:12 to 08-24 06:52 and are
    # wrong -- they average 3.77% where tensorcore averages 49% over the same
    # chips, which is not physically possible. Do not reason from them; they
    # predate this entry and should be deleted rather than trusted.
    ("kubernetes.io/container/accelerator/duty_cycle",
     "k8s_container", 300, "ALIGN_MEAN"),
    # log-storm events on the fact_event timeline; joins to dim_pod
    ("logging.googleapis.com/log_entry_count",
     "k8s_container", 300, "ALIGN_SUM"),

    # ---- measured goodput, from the ml-goodput-measurement library ----
    #
    # These four are the closed decomposition: elapsed = goodput + sum(badput),
    # with disruptions counting the interruptions that produced it. They replace
    # the tensorcore proxy above for any job that records them, and calibrate it
    # for the jobs that cannot -- see fact_goodput_measured in
    # model/06_fact_goodput.sql.
    #
    # They join on workload_id (= MaxText's run_name = the submitted job name),
    # NOT on pod_name: resource.type is compute.googleapis.com/Workload and
    # carries no pod. That is why they bypass fact_metric, whose whole purpose is
    # the dim_pod join.
    #
    # Cumulative GAUGEs written every goodput_upload_interval_seconds (30s by
    # default), so ALIGN_MAX over the bucket keeps the running total rather than
    # averaging it down. Do not switch to ALIGN_RATE: these are not counters, and
    # a run that reuses a name restarts them from zero.
    #
    # Volume is negligible next to the per-container metrics -- one series per
    # (workload, badput category) instead of one per chip.
    ("compute.googleapis.com/workload/goodput_time",
     "compute.googleapis.com/Workload", 300, "ALIGN_MAX"),
    ("compute.googleapis.com/workload/badput_time",
     "compute.googleapis.com/Workload", 300, "ALIGN_MAX"),
    ("compute.googleapis.com/workload/total_elapsed_time",
     "compute.googleapis.com/Workload", 300, "ALIGN_MAX"),
    ("compute.googleapis.com/workload/disruptions",
     "compute.googleapis.com/Workload", 300, "ALIGN_MAX"),

    # ---- the finance denominator ----
    #
    # Reserved capacity is what gets paid for whether or not anything runs on
    # it, so every finance ratio divides by it. It has to be integrated over
    # time rather than read as a level -- reserved chips change when a
    # reservation is resized, and a spot reading would silently restate history.
    #
    # ALIGN_MEAN over the bucket, not ALIGN_MAX: the value is a level, and the
    # mean of a level over a bucket is exactly the chip-hours contributed by
    # that bucket once multiplied by its width. MAX would round every partial
    # change up.
    #
    # Unit is chips. Confirmed against the hardware rather than assumed:
    # ghostfish-luwqsqv4va7tk reports one block of 32 hosts, and TPU7x carries
    # four chips per host, which matches its reserved series of ~128.
    ("compute.googleapis.com/reservation/reserved",
     "compute.googleapis.com/Reservation", 300, "ALIGN_MEAN"),
    ("compute.googleapis.com/reservation/used",
     "compute.googleapis.com/Reservation", 300, "ALIGN_MEAN"),
]

# Removed: tpu.googleapis.com/instance/interruption_count. It always returned
# zero points, and the capability map explains why -- it is scoped to
# tpu_worker / GceTpuWorker, the Cloud TPU VM surface, and has 2 series in the
# entire project. Our TPUs are GKE-managed, so preemption attribution has to
# come from Kubernetes events instead, which fact_event already collects.


_TOKEN: tuple[str, float] | None = None
# Access tokens last an hour. Refresh well inside that, because the failure is
# not graceful: a 90-day backfill ran 55 minutes, hit HTTP 401 on the next
# fetch, and took every chunk it had gathered down with it. A normal run is
# minutes long and never reaches this.
_TOKEN_MAX_AGE_S = 40 * 60


def access_token(force: bool = False) -> str:
    """ADC token, refreshed when it is old enough to be a risk.

    CLOUDSDK_AUTH_ACCESS_TOKEN wins when set -- inside the Cloud Run refresh job
    the entrypoint exports one metadata-server token for the whole run, which
    avoids a ~1.3s gcloud call and matches what bq already reads. That job's
    task timeout is under an hour, so its token cannot expire mid-run; a
    long-running backfill from a workstation can, and does.
    """
    global _TOKEN
    if not force and _TOKEN and time.time() - _TOKEN[1] < _TOKEN_MAX_AGE_S:
        return _TOKEN[0]
    # Only on the very first call. After that the variable holds whatever this
    # function last wrote into it, so reading it back returns the token that
    # just expired and the refresh below can never run -- which is exactly how
    # the first attempt at this fix still died of HTTP 401 after 40 minutes.
    if _TOKEN is None and not force:
        env = os.environ.get("CLOUDSDK_AUTH_ACCESS_TOKEN")
        if env:
            _TOKEN = (env, time.time())
            return env
    fresh = subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    # bq reads the same variable, so refreshing it keeps the loader alive too --
    # otherwise the fetch would recover and the write would start failing.
    os.environ["CLOUDSDK_AUTH_ACCESS_TOKEN"] = fresh
    _TOKEN = (fresh, time.time())
    return fresh


def fetch_series(token, project, metric_type, resource_type,
                 start, end, alignment, aligner):
    """Page through timeSeries.list for one metric over one window."""
    flt = f'metric.type="{metric_type}"'
    if resource_type:
        flt += f' AND resource.type="{resource_type}"'
    params = [
        ("filter", flt),
        ("interval.startTime", start),
        ("interval.endTime", end),
        ("aggregation.alignmentPeriod", f"{alignment}s"),
        ("aggregation.perSeriesAligner", aligner),
        ("pageSize", "2000"),
    ]
    base = (f"https://monitoring.googleapis.com/v3/projects/{project}"
            f"/timeSeries?{urllib.parse.urlencode(params)}")
    url, out = base, []
    while True:
        for attempt in range(4):
            req = urllib.request.Request(
                url, headers={"Authorization": f"Bearer {token}"})
            try:
                page = json.load(urllib.request.urlopen(req, timeout=120))
                break
            except urllib.error.HTTPError as e:
                if e.code not in (429, 500, 502, 503, 504) or attempt == 3:
                    raise RuntimeError(
                        f"{metric_type}: HTTP {e.code} {e.read()[:200]}")
                time.sleep(2 ** attempt)
            except (urllib.error.URLError, TimeoutError, OSError,
                    http.client.HTTPException) as e:
                # Transport-level failures were propagating while HTTP errors
                # retried, and this is the harmful direction: clear_window has
                # already deleted the window and bq_load runs per chunk, so a
                # crash mid-metric leaves it part-cleared and part-reloaded --
                # and the next run's window has moved on, so the uncovered half
                # is never re-fetched. A four-page request under a 120s timeout
                # reaches this. mldiag_poller already catches these.
                if attempt == 3:
                    raise RuntimeError(f"{metric_type}: {type(e).__name__} {e}")
                time.sleep(2 ** attempt)
        out.extend(page.get("timeSeries", []))
        token_next = page.get("nextPageToken")
        if not token_next:
            return out
        url = f"{base}&pageToken={token_next}"


def to_rows(series_list, metric_type, ingested_at):
    """Flatten timeSeries into one row per point."""
    rows = []
    for s in series_list:
        resource_labels = s.get("resource", {}).get("labels", {})
        metric_labels = s.get("metric", {}).get("labels", {})
        for p in s.get("points", []):
            v = p["value"]
            value = (v.get("doubleValue")
                     if "doubleValue" in v
                     else v.get("int64Value"))
            if value is None:
                continue  # distributions/strings are out of scope here
            rows.append({
                "metric_type": metric_type,
                "point_time": p["interval"]["endTime"],
                "value": float(value),
                "resource_type": s.get("resource", {}).get("type"),
                "resource_labels": resource_labels,
                "metric_labels": metric_labels,
                "ingested_at": ingested_at,
            })
    return rows


def clear_window(project, dataset, start, end, metric_types=None):
    """Delete the point_time range we are about to rewrite, so re-runs are exact.

    metric_types narrows the delete to the metrics this run will re-insert. It
    has to move in lockstep with the --only filter: deleting the whole window
    while reloading a subset would drop every other metric in it. Backfilling a
    newly added metric over a wide window is the case that needs this -- a full
    reload of a day of tensorcore samples is thousands of series for no reason.
    """
    # Closed on both ends, because the fetch is (start - 1s, end] and so
    # returns the point at exactly `end`. A half-open delete leaves that point
    # inserted-but-never-deleted, and two runs that snap to the same end_dt --
    # a manual run racing the scheduled one, of which there were nine on
    # 2026-09-14 -- would each insert it.
    where = (f"point_time >= TIMESTAMP('{start}') "
             f"AND point_time <= TIMESTAMP('{end}')")
    if metric_types:
        quoted = ", ".join("'" + m.replace("'", "") + "'" for m in metric_types)
        where += f" AND metric_type IN ({quoted})"
    sql = f"DELETE FROM `{project}.{dataset}.metric_samples` WHERE {where}"
    result = subprocess.run(
        ["bq", f"--project_id={project}", "query", "--use_legacy_sql=false", sql],
        capture_output=True, text=True)
    if result.returncode != 0:
        # first run: the table does not exist yet, which is not an error
        if "Not found" in result.stderr or "not found" in result.stderr:
            return
        sys.exit(f"failed to clear window:\n{result.stderr}")


def bq_load(project, dataset, rows):
    if not rows:
        print("  nothing to load", flush=True)
        return
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        for row in rows:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
        path = fh.name
    cmd = [
        "bq", f"--project_id={project}", "load",
        "--source_format=NEWLINE_DELIMITED_JSON",
        "--time_partitioning_field=point_time",
        "--time_partitioning_type=DAY",
        "--clustering_fields=metric_type",
        f"{dataset}.metric_samples", path,
        ("metric_type:STRING,point_time:TIMESTAMP,value:FLOAT,"
         "resource_type:STRING,resource_labels:JSON,metric_labels:JSON,"
         "ingested_at:TIMESTAMP"),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(path)
    if result.returncode != 0:
        # bq reports load errors on stdout, not stderr, so printing only stderr
        # yields an empty message and hides the real cause.
        sys.exit(f"bq load failed:\n{result.stdout}\n{result.stderr}")
    print(f"  loaded {len(rows)} rows", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=DEFAULT_PROJECT)
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--hours", type=float, default=3.0,
                    help="window to export, ending now")
    ap.add_argument("--chunk-hours", type=float, default=6.0,
                    help="split the window; the API caps points per response")
    ap.add_argument("--only", default="",
                    help="substring of metric_type; export just the matching "
                         "metrics and clear only those. For backfilling a "
                         "newly added metric over a wide window without "
                         "reloading everything else in it.")
    args = ap.parse_args()

    selected = [m for m in METRICS if args.only in m[0]]
    if not selected:
        sys.exit(f"--only {args.only!r} matched none of: "
                 + ", ".join(m[0] for m in METRICS))

    token = access_token()
    # Snap the window to a 300s boundary so every run produces points at the
    # same wall-clock instants.
    #
    # Cloud Monitoring aligns output to the interval start, so a window opening
    # at an arbitrary second puts that run's points on an arbitrary phase.
    # Observed 2026-09-10: one run emitted every sample at :49 past (phase 169),
    # the previous run at phase 186. Within a run the spacing is exactly 300s
    # and all metrics share a timestamp, so nothing was wrong -- until you
    # bucket by wall clock, where a shifting phase gives a five-minute bucket
    # zero points at one boundary and two at the next.
    #
    # Snapping also makes re-collection idempotent by construction: a backfill
    # and the live collector covering the same period now produce identical
    # timestamps, so clear-then-load replaces rows instead of laying a second
    # phase alongside the first.
    end_dt = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    end_dt -= dt.timedelta(seconds=end_dt.timestamp() % 300)
    start_dt = end_dt - dt.timedelta(hours=args.hours)
    ingested_at = end_dt.isoformat()
    iso = lambda d: d.isoformat().replace("+00:00", "Z")

    # One DELETE before any load, scoped to exactly the metrics being reloaded.
    print(f"clearing {iso(start_dt)} .. {iso(end_dt)} "
          f"({len(selected)}/{len(METRICS)} metrics)", flush=True)
    clear_window(args.project, args.dataset, iso(start_dt), iso(end_dt),
                 metric_types=[m[0] for m in selected] if args.only else None)

    total = 0
    for metric_type, resource_type, alignment, aligner in selected:
        print(f"{metric_type} ({aligner} @ {alignment}s)", flush=True)
        metric_total = 0
        cursor = start_dt
        # Loaded per chunk, not accumulated and loaded once at the end. The
        # window is normally an hour or two, where either is the same thing; a
        # backfill is not. Ninety days of per-chip samples is millions of rows,
        # and holding them to write in a single shot means memory grows with the
        # window and a failure anywhere throws away every chunk already fetched.
        # clear_window has already run, so appending per chunk is equally
        # idempotent and partial progress survives.
        while cursor < end_dt:
            chunk_end = min(cursor + dt.timedelta(hours=args.chunk_hours), end_dt)
            token = access_token()          # refreshes itself when stale
            series = fetch_series(
                token, args.project, metric_type, resource_type,
                # One second before the cursor. Cloud Monitoring treats a
                # TimeInterval as (startTime, endTime] -- the start is
                # exclusive -- so a request for [T, T+1h] never returns the
                # sample at exactly T. clear_window deletes the closed range
                # including T, so every run destroyed the boundary sample and
                # could not reload it. With a 30-minute cadence and a one-hour
                # window the boundaries land on :00 and :30, and those were
                # exactly the buckets missing: 48 of 288 a day, 17%.
                # ...but only for the first chunk. clear_window runs once,
                # before this loop, so chunk N fetching (.., chunk_end] and
                # chunk N+1 fetching (chunk_end - 1s, ..] both return the point
                # at chunk_end and nothing deletes the first copy. A live run is
                # a single chunk so it has never fired, but deploy.sh's
                # FIRST_FILL_HOURS=12 against the default --chunk-hours 6 is two
                # chunks, and any wide backfill duplicates once every 6 hours.
                ((cursor - dt.timedelta(seconds=1)) if cursor == start_dt
                 else cursor).isoformat().replace("+00:00", "Z"),
                chunk_end.isoformat().replace("+00:00", "Z"),
                alignment, aligner)
            rows = to_rows(series, metric_type, ingested_at)
            if rows:
                bq_load(args.project, args.dataset, rows)
                metric_total += len(rows)
            cursor = chunk_end
        print(f"  {metric_total} points", flush=True)
        total += metric_total
    print(f"total {total} points", flush=True)


if __name__ == "__main__":
    main()
