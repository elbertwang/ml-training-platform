#!/bin/bash
# The incremental cycle. Run this on a schedule; run deploy.sh only to install
# or after changing the model.
#
#   PROJECT_ID=tpu-for-training MLDIAG_LOCATIONS=us-central1 ./refresh.sh
#
# Order matters. dim_pod must be rebuilt before fact_event and fact_metric,
# because both resolve pods to jobs through it and a pod that first logged in
# this cycle would otherwise have a NULL job_key baked into the facts.
#
# Cost per cycle is dominated by the fact_event rebuild window. Everything reads
# the sink tables and metric_samples, never the linked dataset -- see
# model/04_fact_event.sql for why that distinction is worth ~$1,200/month.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
MLDIAG_LOCATIONS="${MLDIAG_LOCATIONS:-us-central1}"
METRIC_HOURS="${METRIC_HOURS:-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

echo "=== Collect ==="
"${HERE}/collect/mldiag_poller.py"    --project "$PROJECT_ID" \
                                      --locations "$MLDIAG_LOCATIONS" --since-hours 6
"${HERE}/collect/metrics_exporter.py" --project "$PROJECT_ID" --hours "$METRIC_HOURS"

# The sink materialises one table per log id, and new ones appear over time
# (a new component starts logging, a new log id shows up). Rediscover cheaply
# rather than let the union go stale.
python3 "${HERE}/model/build_v_sink_logs.py" --project "$PROJECT_ID"

echo "=== Model ==="
for f in 01_dim_pod 04_fact_event 06_fact_goodput 07_views; do
  printf "  %-18s " "$f"
  if out=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false \
             < "${HERE}/model/${f}.sql" 2>&1); then
    echo "$out" | grep -Eo '(Created|Replaced|Number of affected rows: [0-9]+)[ a-z._-]*' \
      | tr '\n' ' '; echo
  else
    echo "FAILED"; echo "$out" | tail -6; exit 1
  fi
done

echo "=== Freshness ==="
bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=pretty "
SELECT 'fact_event'  AS t, TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(event_time), MINUTE) AS lag_min, COUNT(*) AS rows_
FROM \`${PROJECT_ID}.mlobs_core.fact_event\`
UNION ALL
SELECT 'fact_metric', TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(point_time), MINUTE), COUNT(*)
FROM \`${PROJECT_ID}.mlobs_core.fact_metric\`
UNION ALL
SELECT 'job_hub', TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(last_seen), MINUTE), COUNT(*)
FROM \`${PROJECT_ID}.mlobs_core.job_hub\`"
