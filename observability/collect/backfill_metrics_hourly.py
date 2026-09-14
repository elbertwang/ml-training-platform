#!/usr/bin/env python3
"""Recover accelerator history from beyond Cloud Monitoring's full-resolution window.

    python3 collect/backfill_metrics_hourly.py --project tpu-for-training \
            --from 2026-06-06 --to 2026-08-11

metrics_exporter.py collects at 300s and only ever runs forward, so fact_chip
starts the day the node-scoped metrics were added to it. Measured 2026-09-14:
the utilisation layers of the funnel covered 35 days while the denominator
covered 101, and the 66 uncovered days hold 1,723,477 paid chip-hours against
414,362 in the covered ones. The blind stretch is 4.2x the visible one, and it
is the stretch that matters -- June averaged 2,034 reserved chips against 511
in July and August.

None of that is lost. Cloud Monitoring serves these metrics back to
2026-03-11, which is not a retention boundary but the creation time of cluster
tpu-training-antgroup: the data reaches back as far as the cluster exists.
Measured per metric over a 365-day window, node tensorcore and memory-bandwidth
return 187 days, node and container duty_cycle 183, reservation/reserved 184.

**Two resolutions, and the second one is a trap.** A 300s-aligned request
returns real 300s points up to about day 40 and 600s points from day 45 -- the
documented six-week downsampling. fact_chip's consumers used to read a row as
300 seconds, so loading 600s history through the normal path would have
reported half the work with no error anywhere. That is why fact_chip carries
interval_s and why this script writes it explicitly rather than letting anything
downstream assume.

**Why ALIGN_COUNT as well as ALIGN_MEAN.** Asking for 3600s alignment collapses
each hour to one point, which is all a daily figure needs -- but the mean alone
cannot say whether it averaged six underlying samples or one. A chip whose node
came up ten minutes before the hour ended would otherwise be billed a full
chip-hour. So each metric is fetched twice and the two are zipped on
(series, timestamp): value from the mean, interval_s from the count times the
underlying sampling period, which is itself read off the busiest bucket of the
day rather than assumed. Presence stays exact and the row count does not change.

Rows go to mlobs_raw.metric_hourly, not metric_samples. The two never overlap --
this one starts where the live collector's history ends -- and keeping them
apart means a re-run of either cannot silently double-count the other's window.
11h_fact_chip_history.sql reads this table into the same fact_chip the live path
writes, so there is still exactly one place where raw metrics become chip facts.

One day at a time, deleting that day before loading it, so a failure costs one
day rather than the run and a re-run is exact.
"""
import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile

from metrics_exporter import access_token, fetch_series

TABLE = "metric_hourly"

# The period Cloud Monitoring actually serves once a request falls outside the
# six-week window. Verified against the returned point spacing rather than
# assumed: a 300s request at 40 days back came back 300s apart, at 60 and 100
# and 150 days back it came back 600s apart.
DOWNSAMPLED_PERIOD_S = 600

# Samples per hour at each cadence Cloud Monitoring has actually been observed
# to serve for these metrics: 60 raw (inside the six-week window), 6 downsampled
# (outside it). 12 is kept because a 300s-aligned source would report it.
KNOWN_CADENCES = {6, 12, 60}

# Aligned to 3600s: one point per chip per hour, which is the grain chip_hourly
# publishes and more than a daily figure needs.
ALIGNMENT_S = 3600

NODE_METRICS = [
    "kubernetes.io/node/accelerator/tensorcore_utilization",
    "kubernetes.io/node/accelerator/memory_bandwidth_utilization",
    "kubernetes.io/node/accelerator/duty_cycle",
]
# Carries pod_name in its resource labels -- at 100 days back as well as today,
# checked -- which is the only channel that knows whose work sat on a chip.
# job_key still cannot be recovered that far: dim_pod is built from GKE labels
# in logs and _Default keeps 30 days.
CONTAINER_METRICS = [
    "kubernetes.io/container/accelerator/tensorcore_utilization",
]
RESERVATION_METRICS = [
    "compute.googleapis.com/reservation/reserved",
    "compute.googleapis.com/reservation/used",
]

SCHEMA = ("metric_type:STRING,point_time:TIMESTAMP,value:FLOAT,"
          "resource_type:STRING,resource_labels:JSON,metric_labels:JSON,"
          "interval_s:INT64,ingested_at:TIMESTAMP")


def series_key(s):
    """Identity of a time series, stable across the mean and count requests."""
    r = s.get("resource", {})
    m = s.get("metric", {})
    return (r.get("type"),
            json.dumps(r.get("labels", {}), sort_keys=True),
            json.dumps(m.get("labels", {}), sort_keys=True))


def fetch_day(token, project, metric_type, day, ingested_at):
    """One day of one metric as rows, with interval_s measured not assumed.

    The mean gives the level and the count gives how much of the hour was
    actually sampled. A point present in the mean but absent from the count is
    dropped rather than guessed at: it has no defensible width.
    """
    # One alignment period before midnight, because Cloud Monitoring's interval
    # is (start, end]: asking for exactly [00:00, 24:00) returns the buckets
    # ending 01:00 through 00:00-next-day, so the day's own 00:00 bucket belongs
    # to the previous day's request. That is survivable on its own -- the
    # previous day's fetch writes it, dated correctly -- but this loop runs
    # forward and clear_day() then deletes it before the current day's fetch,
    # which cannot produce it. Every day came out 23 hours long: a silent 4.2%
    # shortfall in vm_chip_hours. Widening the window and filtering on the date
    # keeps each day's fetch self-sufficient.
    start = (dt.datetime.combine(day, dt.time()) -
             dt.timedelta(seconds=ALIGNMENT_S)).strftime("%Y-%m-%dT%H:%M:%SZ")
    end = f"{(day + dt.timedelta(days=1)).isoformat()}T00:00:00Z"

    means = fetch_series(token, project, metric_type, None,
                         start, end, ALIGNMENT_S, "ALIGN_MEAN")
    counts = fetch_series(token, project, metric_type, None,
                          start, end, ALIGNMENT_S, "ALIGN_COUNT")

    n_by_key, max_n = {}, 0
    for s in counts:
        bucket = n_by_key.setdefault(series_key(s), {})
        for p in s.get("points", []):
            v = p["value"]
            n = v.get("int64Value", v.get("doubleValue"))
            if n is not None:
                n = int(float(n))
                bucket[p["interval"]["endTime"]] = n
                max_n = max(max_n, n)

    # The underlying sampling period, measured rather than assumed. A full hour
    # holds the most samples the resolution allows, so the busiest bucket of the
    # day gives it away: 6 means 600s, 12 means 300s. Hard-coding 600 is right
    # only past the six-week downsampling boundary -- inside it a half-empty
    # hour of 300s samples would be credited with twice the seconds it had.
    if max_n in KNOWN_CADENCES:
        period_s = ALIGNMENT_S // max_n
    else:
        # Only the measured cadences divide the hour exactly. A stray count --
        # 7, say -- would yield 514s and push a wrong interval_s straight into
        # fact_chip's chip-hours with nothing to flag it, so snap to the nearest
        # real cadence and say so rather than trusting the arithmetic.
        nearest = min(KNOWN_CADENCES, key=lambda k: abs(k - max_n)) if max_n else 6
        period_s = ALIGNMENT_S // nearest
        print(f"    {metric_type.split('/')[-1]} {day}: busiest bucket held "
              f"{max_n} samples, not one of {sorted(KNOWN_CADENCES)}; "
              f"treating the cadence as {period_s}s", flush=True)

    rows, unmatched = [], 0
    for s in means:
        key = series_key(s)
        counted = n_by_key.get(key, {})
        resource = s.get("resource", {})
        for p in s.get("points", []):
            v = p["value"]
            value = v.get("doubleValue", v.get("int64Value"))
            if value is None:
                continue
            ts = p["interval"]["endTime"]
            # The widened window reaches back into the previous day; that bucket
            # is the previous day's to write and clear.
            if ts[:10] != day.isoformat():
                continue
            n = counted.get(ts)
            if not n:
                unmatched += 1
                continue
            rows.append({
                "metric_type": metric_type,
                "point_time": ts,
                "value": float(value),
                "resource_type": resource.get("type"),
                "resource_labels": resource.get("labels", {}),
                "metric_labels": s.get("metric", {}).get("labels", {}),
                # Capped at the alignment period: a stray extra sample in a
                # bucket would otherwise claim more than the hour it sits in.
                "interval_s": min(n * period_s, ALIGNMENT_S),
                "ingested_at": ingested_at,
            })
    return rows, unmatched


def clear_day(project, dataset, table, day, metric_types):
    quoted = ", ".join("'" + m.replace("'", "") + "'" for m in metric_types)
    sql = (f"DELETE FROM `{project}.{dataset}.{table}` "
           f"WHERE DATE(point_time) = '{day.isoformat()}' "
           f"AND metric_type IN ({quoted})")
    r = subprocess.run(["bq", f"--project_id={project}", "query",
                        "--use_legacy_sql=false", sql],
                       capture_output=True, text=True)
    if r.returncode != 0:
        # bq reports this on stdout, not stderr. Checking only stderr made the
        # first run die with an empty message on the day the table did not exist
        # yet -- which is every first run.
        both = r.stdout + r.stderr
        if "ot found" in both:
            return  # first day of the first run: nothing to clear
        sys.exit(f"failed to clear {day}:\n{both}")


def bq_load(project, dataset, table, rows, schema):
    if not rows:
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        for row in rows:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
        path = fh.name
    cmd = ["bq", f"--project_id={project}", "load",
           "--source_format=NEWLINE_DELIMITED_JSON",
           "--time_partitioning_field=point_time",
           "--time_partitioning_type=DAY",
           "--clustering_fields=metric_type",
           f"{dataset}.{table}", path, schema]
    r = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(path)
    if r.returncode != 0:
        # bq puts load errors on stdout, so stderr alone reads as an empty cause
        sys.exit(f"load failed:\n{r.stdout}\n{r.stderr}")
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--dataset", default="mlobs_raw")
    ap.add_argument("--from", dest="start", required=True,
                    help="first day, inclusive, YYYY-MM-DD")
    ap.add_argument("--to", dest="end", required=True,
                    help="last day, exclusive, YYYY-MM-DD")
    ap.add_argument("--metrics", default="node",
                    help="node | container | reservation | all, comma separated")
    ap.add_argument("--target", default=TABLE,
                    help="destination table; reservation history goes to "
                         "metric_samples, whose consumers already measure the "
                         "sample interval with LAG")
    ap.add_argument("--print", dest="dry", action="store_true")
    args = ap.parse_args()

    groups = {"node": NODE_METRICS, "container": CONTAINER_METRICS,
              "reservation": RESERVATION_METRICS}
    wanted = []
    for name in args.metrics.split(","):
        name = name.strip()
        if name == "all":
            wanted = NODE_METRICS + CONTAINER_METRICS + RESERVATION_METRICS
            break
        if name not in groups:
            sys.exit(f"unknown metric group {name!r}; pick from {list(groups)}")
        wanted += groups[name]

    day = dt.date.fromisoformat(args.start)
    last = dt.date.fromisoformat(args.end)
    if day >= last:
        sys.exit("--from must be before --to")

    total, total_unmatched, started = 0, 0, dt.datetime.now(dt.timezone.utc)
    all_skipped = []
    print(f"  {args.start} .. {args.end} ({(last - day).days} days), "
          f"{len(wanted)} metrics -> {args.dataset}.{args.target}", flush=True)

    while day < last:
        ingested_at = dt.datetime.now(dt.timezone.utc).isoformat()
        token = access_token()          # refreshes itself past 40 minutes
        rows, unmatched, fetched, skipped = [], 0, [], []
        for metric in wanted:
            try:
                r, u = fetch_day(token, args.project, metric, day, ingested_at)
            except RuntimeError as e:
                # One unreadable metric-day must not discard the rest of the run
                # -- and must not discard its own existing rows either. It is
                # left out of `fetched`, so clear_day below does not touch it.
                # Clearing all of `wanted` and reloading only what succeeded
                # turned a transient 5xx into permanent deletion of that
                # metric's day, while still printing a row count and "done."
                print(f"  {day} {metric.split('/')[-1]}: {e}", flush=True)
                skipped.append(metric)
                continue
            fetched.append(metric)
            rows += r
            unmatched += u
        all_skipped.extend((day, m) for m in skipped)
        if args.target == "metric_samples":
            # fin_capacity_daily derives the sample width with LAG over whatever
            # spacing it finds, so the reservation series need no interval_s and
            # that table has no column for one. Carrying it would fail the load.
            rows = [{k: v for k, v in r.items() if k != "interval_s"}
                    for r in rows]
        if not args.dry and fetched:
            clear_day(args.project, args.dataset, args.target, day, fetched)
            bq_load(args.project, args.dataset, args.target, rows,
                    SCHEMA.replace("interval_s:INT64,", "")
                    if args.target == "metric_samples" else SCHEMA)
        total += len(rows)
        total_unmatched += unmatched
        elapsed = (dt.datetime.now(dt.timezone.utc) - started).total_seconds()
        print(f"  {day}  {len(rows):>7,} rows"
              f"{f' ({unmatched} unmatched)' if unmatched else ''}"
              f"   total {total:>10,}   {elapsed/60:.1f} min", flush=True)
        day += dt.timedelta(days=1)

    print(f"  done. {total:,} rows, {total_unmatched:,} points dropped for "
          f"having no count alongside the mean.")
    if all_skipped:
        # Non-zero, because a backfill that half-ran and reported success is
        # how a repair becomes a second outage.
        print(f"  {len(all_skipped)} metric-days could not be fetched and were "
              f"left untouched; re-run those days:", file=sys.stderr)
        for d, m in all_skipped[:20]:
            print(f"    {d} {m}", file=sys.stderr)
        sys.exit(1)
    if not args.dry:
        print(f"  next: model/11h_fact_chip_history.sql over the same range.")


if __name__ == "__main__":
    main()
