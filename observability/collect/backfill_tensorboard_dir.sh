#!/bin/bash
# Backfill `Config param tensorboard_dir` lines into
# mlobs_raw.tensorboard_dir_backfill so dim_job_artifact covers runs that
# started before the sink filter learned about them.
#
#   DAYS=30 PROJECT_ID=tpu-for-training ./backfill_tensorboard_dir.sh
#
# A sink is not retroactive: the clause was added to mlobs-selective on
# 2026-09-09, so without this every job already running has no TensorBoard link.
#
# Read through `gcloud logging read`, NOT through a BigQuery scan of
# defaultLink._AllLogs. Only runs with a real base_output_directory emit the
# line -- most CI jobs leave it empty -- so the whole result set is tiny: 38
# entries over seven days, fetched in 11 seconds. The equivalent _AllLogs scan
# is ~10 TiB and about $67, which is the wrong tool by three orders of
# magnitude. See collect/backfill_step_lines.sh for the case where that cost is
# actually unavoidable, because there the predicate is on message content
# across every container log.
#
# Bounded by the _Default bucket's 30-day retention, same as the other
# backfills.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
DATASET="${DATASET:-mlobs_raw}"
DAYS="${DAYS:-30}"
TABLE="${DATASET}.tensorboard_dir_backfill"
TMP=$(mktemp /tmp/tbdir.XXXXXX.json)
trap 'rm -f "$TMP"' EXIT

echo "  reading ${DAYS} days of Config param tensorboard_dir"
# `gs://` in the filter drops the empty-value lines at the server rather than
# after transfer; they outnumber the useful ones by roughly ten to one.
gcloud logging read \
  'resource.type="k8s_container" AND textPayload:"Config param tensorboard_dir: gs://"' \
  --project "$PROJECT_ID" --freshness "${DAYS}d" --limit 100000 \
  --format="csv[no-heading](timestamp,resource.labels.pod_name,textPayload)" \
| python3 -c '
import csv, json, re, sys
seen = 0
for row in csv.reader(sys.stdin):
    if len(row) < 3:
        continue
    ts, pod, payload = row[0], row[1], ",".join(row[2:])
    m = re.search(r"Config param tensorboard_dir:\s*(gs://\S+)", payload)
    if not m or not pod:
        continue
    print(json.dumps({"timestamp": ts, "pod_name": pod,
                      "tensorboard_gs": m.group(1).rstrip("/")},
                     separators=(",", ":")))
    seen += 1
print(f"  parsed {seen} lines", file=sys.stderr)
' > "$TMP"

if [[ ! -s "$TMP" ]]; then
  echo "  nothing to load"
  exit 0
fi

# WRITE_TRUNCATE: the window is the whole retained history every time, so the
# file is the complete picture and a re-run cannot accumulate duplicates.
bq --project_id="$PROJECT_ID" load \
  --source_format=NEWLINE_DELIMITED_JSON --replace \
  "$TABLE" "$TMP" \
  "timestamp:TIMESTAMP,pod_name:STRING,tensorboard_gs:STRING" >/dev/null

bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
  "SELECT CONCAT('  ', CAST(COUNT(*) AS STRING), ' rows, ',
                 CAST(COUNT(DISTINCT tensorboard_gs) AS STRING), ' distinct runs')
   FROM \`${PROJECT_ID}.${TABLE}\`" | tail -1

echo "  done. Re-run model/03d_dim_job_artifact.sql to merge these in."
