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
    # goodput input; joins to dim_pod
    ("kubernetes.io/container/accelerator/tensorcore_utilization",
     "k8s_container", 300, "ALIGN_MEAN"),
    # log-storm events on the fact_event timeline; joins to dim_pod
    ("logging.googleapis.com/log_entry_count",
     "k8s_container", 300, "ALIGN_SUM"),
    # preemption attribution. Wired up but unproven -- returned zero points in
    # every window sampled so far.
    ("tpu.googleapis.com/instance/interruption_count",
     None, 300, "ALIGN_SUM"),
]


def access_token() -> str:
    return subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


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


def clear_window(project, dataset, start, end):
    """Delete the point_time range we are about to rewrite, so re-runs are exact."""
    sql = (f"DELETE FROM `{project}.{dataset}.metric_samples` "
           f"WHERE point_time >= TIMESTAMP('{start}') "
           f"AND point_time < TIMESTAMP('{end}')")
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
        sys.exit(f"bq load failed:\n{result.stderr}")
    print(f"  loaded {len(rows)} rows", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=DEFAULT_PROJECT)
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--hours", type=float, default=3.0,
                    help="window to export, ending now")
    ap.add_argument("--chunk-hours", type=float, default=6.0,
                    help="split the window; the API caps points per response")
    args = ap.parse_args()

    token = access_token()
    end_dt = dt.datetime.now(dt.timezone.utc)
    start_dt = end_dt - dt.timedelta(hours=args.hours)
    ingested_at = end_dt.isoformat()
    iso = lambda d: d.isoformat().replace("+00:00", "Z")

    # One DELETE for the whole window across all metrics, before any load.
    print(f"clearing {iso(start_dt)} .. {iso(end_dt)}", flush=True)
    clear_window(args.project, args.dataset, iso(start_dt), iso(end_dt))

    total = 0
    for metric_type, resource_type, alignment, aligner in METRICS:
        print(f"{metric_type} ({aligner} @ {alignment}s)", flush=True)
        rows = []
        cursor = start_dt
        while cursor < end_dt:
            chunk_end = min(cursor + dt.timedelta(hours=args.chunk_hours), end_dt)
            series = fetch_series(
                token, args.project, metric_type, resource_type,
                cursor.isoformat().replace("+00:00", "Z"),
                chunk_end.isoformat().replace("+00:00", "Z"),
                alignment, aligner)
            rows.extend(to_rows(series, metric_type, ingested_at))
            cursor = chunk_end
        print(f"  {len(rows)} points", flush=True)
        bq_load(args.project, args.dataset, rows)
        total += len(rows)
    print(f"total {total} points", flush=True)


if __name__ == "__main__":
    main()
