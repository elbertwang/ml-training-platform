#!/usr/bin/env python3
"""Poll the ML Diagnostics (hypercomputecluster) REST API into BigQuery raw tables.

Design rule: this loader lands API responses *verbatim*. It does no parsing,
flattening or joining -- all of that happens in SQL on top of `mlobs_raw`.
When the API shape changes, only the SQL needs updating and the raw history
can be replayed.

Tables written (append-only, deduped downstream by (name, etag)):
  mlobs_raw.mldiag_runs    name, ingested_at, payload
  mlobs_raw.mldiag_events  name, run_name, ingested_at, payload

Usage:
  ./mldiag_poller.py --backfill                 # every run + its events
  ./mldiag_poller.py --since-hours 6            # incremental: recent + ACTIVE runs
"""

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

API_ROOT = "https://hypercomputecluster.googleapis.com/v1alpha"
DEFAULT_PROJECT = os.environ.get("MLOBS_PROJECT", "tpu-for-training")
DEFAULT_LOCATION = os.environ.get("MLOBS_LOCATION", "us-central1")
DEFAULT_DATASET = os.environ.get("MLOBS_RAW_DATASET", "mlobs_raw")

# The API returns 200 + {} for a run that does not exist in this location,
# so the caller must never treat an empty body as "no events" without having
# confirmed the parent run resolves here. See docs/ml-diagnostics research.
EMPTY_IS_AMBIGUOUS = True


def parse_ts(stamp: str):
    """The API emits 9-digit fractional seconds; fromisoformat accepts at most 6."""
    if not stamp:
        return None
    normalised = stamp.replace("Z", "+00:00")
    if "." in normalised:
        head, _, tail = normalised.partition(".")
        digits = tail[:-6] if tail.endswith("+00:00") else tail
        normalised = f"{head}.{digits[:6]}+00:00"
    try:
        return dt.datetime.fromisoformat(normalised)
    except ValueError:
        return None


def access_token() -> str:
    """ADC token. On CAA-restricted VMs this is the only path that works."""
    return subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


class Api:
    def __init__(self, token: str, project: str, location: str):
        self.token = token
        self.base = f"{API_ROOT}/projects/{project}/locations/{location}"

    def get(self, url: str, retries: int = 4) -> dict:
        for attempt in range(retries):
            req = urllib.request.Request(
                url, headers={"Authorization": f"Bearer {self.token}"}
            )
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return json.load(resp)
            except urllib.error.HTTPError as e:
                # 429/5xx are worth retrying; 4xx client errors are not.
                if e.code not in (429, 500, 502, 503, 504) or attempt == retries - 1:
                    raise
            except (urllib.error.URLError, TimeoutError):
                if attempt == retries - 1:
                    raise
            import time
            time.sleep(2 ** attempt)
        raise RuntimeError("unreachable")

    def list_runs(self) -> list:
        runs, token = [], None
        while True:
            url = f"{self.base}/machineLearningRuns?pageSize=1000"
            if token:
                url += f"&pageToken={token}"
            page = self.get(url)
            runs.extend(page.get("machineLearningRuns", []))
            token = page.get("nextPageToken")
            if not token:
                return runs

    def list_events(self, run_name: str) -> list:
        """run_name is the full resource name; events are a sub-collection."""
        events, token = [], None
        while True:
            url = f"{API_ROOT}/{run_name}/monitoredEvents?pageSize=100"
            if token:
                url += f"&pageToken={token}"
            page = self.get(url)
            events.extend(page.get("monitoredEvents", []))
            token = page.get("nextPageToken")
            if not token:
                return events


def bq_load(project: str, dataset: str, table: str, rows: list, schema: str) -> int:
    """Append NDJSON rows into a day-partitioned, name-clustered table."""
    if not rows:
        print(f"  {table}: nothing to load")
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        for row in rows:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
        path = fh.name
    cmd = [
        "bq", f"--project_id={project}", "load",
        "--source_format=NEWLINE_DELIMITED_JSON",
        "--time_partitioning_field=ingested_at",
        "--time_partitioning_type=DAY",
        "--clustering_fields=name",
        f"{dataset}.{table}", path, schema,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(path)
    if result.returncode != 0:
        sys.exit(f"bq load failed for {table}:\n{result.stderr}")
    print(f"  {table}: loaded {len(rows)} rows")
    return len(rows)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=DEFAULT_PROJECT)
    ap.add_argument("--location", default=DEFAULT_LOCATION)
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--backfill", action="store_true",
                    help="fetch events for every run, not just recent ones")
    ap.add_argument("--since-hours", type=float, default=6.0,
                    help="incremental window for event polling")
    ap.add_argument("--concurrency", type=int, default=24)
    args = ap.parse_args()

    api = Api(access_token(), args.project, args.location)
    now = dt.datetime.now(dt.timezone.utc)
    ingested_at = now.isoformat()

    print(f"[{ingested_at}] listing runs in {args.project}/{args.location} ...")
    runs = api.list_runs()
    print(f"  {len(runs)} runs")

    bq_load(args.project, args.dataset, "mldiag_runs",
            [{"name": r["name"], "ingested_at": ingested_at, "payload": r}
             for r in runs],
            "name:STRING,ingested_at:TIMESTAMP,payload:JSON")

    # An ACTIVE run can still open new events, and a run that just finished may
    # have events written slightly after its endTime -- so poll both.
    if args.backfill:
        targets = runs
    else:
        cutoff = now - dt.timedelta(hours=args.since_hours)
        def recent(r):
            if r.get("runPhase") == "ACTIVE":
                return True
            stamp = parse_ts(r.get("updateTime") or r.get("createTime") or "")
            return stamp is not None and stamp >= cutoff
        targets = [r for r in runs if recent(r)]
    print(f"polling monitoredEvents for {len(targets)} runs "
          f"(concurrency {args.concurrency}) ...")

    event_rows, failures = [], 0
    with concurrent.futures.ThreadPoolExecutor(args.concurrency) as pool:
        futures = {pool.submit(api.list_events, r["name"]): r for r in targets}
        for done in concurrent.futures.as_completed(futures):
            run = futures[done]
            try:
                for ev in done.result():
                    event_rows.append({
                        "name": ev["name"],
                        "run_name": run["name"],
                        "ingested_at": ingested_at,
                        "payload": ev,
                    })
            except Exception as exc:  # keep going; report the count at the end
                failures += 1
                print(f"  ! {run.get('displayName')}: {exc}", file=sys.stderr)

    print(f"  {len(event_rows)} events, {failures} run(s) failed")
    bq_load(args.project, args.dataset, "mldiag_events", event_rows,
            "name:STRING,run_name:STRING,ingested_at:TIMESTAMP,payload:JSON")

    if failures:
        sys.exit(f"{failures} run(s) failed to poll -- see stderr above")


if __name__ == "__main__":
    main()
