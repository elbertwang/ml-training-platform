#!/bin/bash
# Provision the observability platform into one project. Idempotent.
#
#   PROJECT_ID=tpu-launchpad-playground ./deploy.sh
#
# Location matters: the Log Analytics linked dataset (`defaultLink`) lives in
# the US multi-region and BigQuery cannot query across locations, so mlobs_raw
# and mlobs_core must be US too -- not us-central1. The script reads
# defaultLink's location and follows it.
#
# The model SQL uses unqualified dataset names and is deployed with
# `bq --project_id=$PROJECT_ID`, so the same files serve every project.
#
# This installs the data plane only -- datasets, sink, model. The two things
# that keep it alive and make it visible are separate, because they have
# different blast radii and are redeployed on different cadences:
#
#   schedule/deploy.sh     the refresh on Cloud Scheduler
#   serve/grafana/deploy.sh  the dashboard on Cloud Run
#
# STAGES controls which of the three run. Default is all of them; use
# STAGES=data to install just this one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib/gcp.sh"

PROJECT_ID="${PROJECT_ID:-tpu-for-training}"
WAIT_SINK_SECONDS="${WAIT_SINK_SECONDS:-300}"
STAGES="${STAGES:-data,schedule,serve}"

require_token

bqq() { bq --project_id="$PROJECT_ID" query --use_legacy_sql=false "$@"; }

echo "=== Target: ${PROJECT_ID} ==="

# --- location: follow defaultLink so the model can join the linked dataset ---
LOCATION=$(bq --project_id="$PROJECT_ID" show --format=prettyjson defaultLink 2>/dev/null \
           | python3 -c 'import sys,json;print(json.load(sys.stdin)["location"])' 2>/dev/null || true)
if [[ -z "$LOCATION" ]]; then
  LOCATION="US"
  echo "  no defaultLink dataset found; defaulting to ${LOCATION}"
  echo "  (enable Log Analytics on _Default and create a linked dataset to use it)"
else
  echo "  defaultLink is in ${LOCATION}; colocating datasets there"
fi

echo "=== Datasets (${LOCATION}, physical storage billing) ==="
for DS in mlobs_raw mlobs_core; do
  if bq --project_id="$PROJECT_ID" show --dataset "${PROJECT_ID}:${DS}" >/dev/null 2>&1; then
    echo "  ${DS}: exists"
  else
    # PHYSICAL is ~5x cheaper than LOGICAL for log-shaped data and switching
    # later is rate-limited, so set it at creation. Projects whose billing
    # account holds flat-rate/reservation commitments reject it outright, in
    # which case LOGICAL is the only option and storage costs more.
    if err=$(bq --project_id="$PROJECT_ID" mk --dataset --location="$LOCATION" \
               --storage_billing_model=PHYSICAL \
               --description="ML observability platform - ${DS}" \
               "${PROJECT_ID}:${DS}" 2>&1); then
      echo "  ${DS}: created (physical billing)"
    elif grep -q "physical billing model is not supported" <<<"$err"; then
      bq --project_id="$PROJECT_ID" mk --dataset --location="$LOCATION" \
         --description="ML observability platform - ${DS}" \
         "${PROJECT_ID}:${DS}" >/dev/null
      echo "  ${DS}: created (LOGICAL billing -- project has flat-rate commitments,"
      echo "         physical billing rejected; storage will cost more than planned)"
    else
      echo "  ${DS}: FAILED"; echo "$err" | tail -3; exit 1
    fi
  fi
done

echo "=== Log sink ==="
PROJECT_ID="$PROJECT_ID" bash "${HERE}/collect/create_log_sink.sh"

# --- the model reads sink tables, which only exist once logs have flowed ---
echo "=== Waiting for sink delivery (up to ${WAIT_SINK_SECONDS}s) ==="
deadline=$((SECONDS + WAIT_SINK_SECONDS))
while true; do
  have=$(bq --project_id="$PROJECT_ID" ls -n 1000 mlobs_raw 2>/dev/null \
         | grep -cE '^\s+(stdout|stderr)\s' || true)
  if [[ "${have:-0}" -ge 1 ]]; then echo "  sink tables present"; break; fi
  if (( SECONDS >= deadline )); then
    echo "  TIMED OUT waiting for mlobs_raw.stdout/stderr."
    echo "  The sink is not retroactive, so this just means no matching log has"
    echo "  been written yet. Re-run deploy.sh once the cluster is producing logs."
    exit 1
  fi
  sleep 15
done

echo "=== Config table ==="
RETENTION=$(gcloud logging buckets describe _Default --location=global \
            --project="$PROJECT_ID" --format="value(retentionDays)" 2>/dev/null || echo 30)
bqq "CREATE OR REPLACE TABLE mlobs_core.dim_config AS
     SELECT '${PROJECT_ID}' AS project_id,
            '${LOCATION}'   AS bq_location,
            ${RETENTION}    AS log_retention_days" >/dev/null
echo "  project_id=${PROJECT_ID} location=${LOCATION} log_retention_days=${RETENTION}"

# The model references metric_samples, which metrics_exporter.py creates on its
# first load. Bootstrap it empty so `deploy.sh` works on a fresh project before
# any metrics have been exported.
bqq "CREATE TABLE IF NOT EXISTS mlobs_raw.metric_samples (
       metric_type STRING, point_time TIMESTAMP, value FLOAT64,
       resource_type STRING, resource_labels JSON, metric_labels JSON,
       ingested_at TIMESTAMP)
     PARTITION BY DATE(point_time) CLUSTER BY metric_type" >/dev/null

# CREATE TABLE IF NOT EXISTS is a no-op once the table exists, so a project
# whose table was first created by an older metrics_exporter.py keeps that old
# schema forever and every subsequent `bq load` fails with "Cannot add fields".
# tpu-for-training hit exactly this: the table predated `ingested_at`. Adding
# the column is purely additive -- existing rows get NULL -- so reconcile it
# here rather than making the operator notice a load failure.
bqq "ALTER TABLE mlobs_raw.metric_samples
     ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMP" >/dev/null

# fact_event is created with CREATE TABLE IF NOT EXISTS and then filled
# incrementally, so a model change that adds a column (attempt_uid, say) leaves
# an old table in place and the INSERT fails on column count. It is fully
# derivable from the sink, so dropping it on schema drift is safe and cheaper
# than an ALTER dance. History outside the rebuild window is lost, which is why
# only derived tables are treated this way.
EXPECTED_FACT_EVENT_COLS=$(grep -oE '^  [a-z_]+ +(TIMESTAMP|STRING|INT64)' \
  "${HERE}/model/04_fact_event.sql" | awk '{print $1}' | sort | tr '\n' ',')
ACTUAL_FACT_EVENT_COLS=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false \
  --format=csv "SELECT STRING_AGG(column_name, ',' ORDER BY column_name)
                FROM mlobs_core.INFORMATION_SCHEMA.COLUMNS
                WHERE table_name = 'fact_event'" 2>/dev/null | tail -1)
if [[ -n "$ACTUAL_FACT_EVENT_COLS" && "$ACTUAL_FACT_EVENT_COLS" != "NULL" ]]; then
  if [[ "${EXPECTED_FACT_EVENT_COLS%,}" != "$(tr ',' '\n' <<<"$ACTUAL_FACT_EVENT_COLS" | sort | tr '\n' ',' | sed 's/,$//')," ]]; then
    echo "  fact_event schema drifted; dropping so it rebuilds"
    bq --project_id="$PROJECT_ID" rm -f -t "${PROJECT_ID}:mlobs_core.fact_event" >/dev/null
  fi
fi

echo "=== Discovering sink log tables ==="
python3 "${HERE}/model/build_v_sink_logs.py" --project "$PROJECT_ID"

echo "=== Model ==="
for f in "${HERE}"/model/*.sql; do
  printf "  %-26s " "$(basename "$f")"
  if out=$(bqq < "$f" 2>&1); then
    echo "$out" | grep -Eo '(Created|Replaced|Number of affected rows: [0-9]+)[ a-z._-]*' \
      | tr '\n' ' '; echo
  else
    echo "FAILED"; echo "$out" | tail -8; exit 1
  fi
done

# A sink is not retroactive, so a fresh install only knows about pods that have
# logged since it was created. Seed the model from what already exists before
# handing over to the scheduler.
echo "=== First fill ==="
"${HERE}/collect/mldiag_poller.py"    --project "$PROJECT_ID" \
                                      --locations "${MLDIAG_LOCATIONS:-us-central1}" --backfill
"${HERE}/collect/metrics_exporter.py" --project "$PROJECT_ID" --hours "${FIRST_FILL_HOURS:-12}"
bqq < "${HERE}/model/04_fact_event.sql" >/dev/null
bqq < "${HERE}/model/06_fact_goodput.sql" >/dev/null
bqq < "${HERE}/model/07_views.sql" >/dev/null
echo "  seeded"

if [[ ",${STAGES}," == *",schedule,"* ]]; then
  echo
  PROJECT_ID="$PROJECT_ID" bash "${HERE}/schedule/deploy.sh"
fi

if [[ ",${STAGES}," == *",serve,"* ]]; then
  echo
  PROJECT_ID="$PROJECT_ID" bash "${HERE}/serve/grafana/deploy.sh"
fi

cat <<EOF

Done.
  Pods older than the sink:  DAYS=30 PROJECT_ID=${PROJECT_ID} ${HERE}/collect/backfill_pod_labels.sh
  Ad-hoc refresh:            PROJECT_ID=${PROJECT_ID} ${HERE}/refresh.sh
EOF
