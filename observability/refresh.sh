#!/bin/bash
# The incremental cycle. Run this on a schedule; run deploy.sh only to install
# or after changing the model.
#
#   PROJECT_ID=tpu-for-training MLDIAG_LOCATIONS=us-central1 ./refresh.sh
#
# Order matters. dim_pod must be rebuilt before fact_event, fact_metric and
# fact_step, because all three resolve pods to jobs through it and a pod that
# first logged in this cycle would otherwise have a NULL job_key baked into the
# facts. 08_views stays last: it materialises job_hub from everything above.
#
# Cost per cycle is dominated by the two rebuild windows, and both are bounded
# on purpose. Everything reads the sink tables and metric_samples, never the
# linked dataset -- see model/04_fact_event.sql for why that distinction is
# worth ~$1,200/month, and model/06_fact_goodput.sql for why fact_metric is
# incremental rather than CREATE OR REPLACE (~$88/month at 30-day retention).
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
MLDIAG_LOCATIONS="${MLDIAG_LOCATIONS:-us-central1}"
METRIC_HOURS="${METRIC_HOURS:-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

echo "=== Collect ==="
# Collectors are ranked, and one failing no longer stops the others or the model.
#
# This used to be four bare commands under `set -e`. On 2026-09-14 a 403 from a
# cosmetic link lookup aborted the run before a single model file executed, and
# mldiag_poller -- which had no business going first -- ran first and had
# exactly the same power. The metric
# window is one hour and the cadence thirty minutes, so two consecutive aborts
# lose accelerator samples permanently. Letting an unrelated collector hold that
# hostage is the wrong trade.
#
#   required  failing means the model would be built on data missing in a way it
#             cannot detect. Exit non-zero so the job retries -- maxRetries is 1
#             and every collector is idempotent, so a retry re-collects.
#   optional  failing degrades something the model does not read. Say so loudly,
#             keep going, exit 0. A retry here would rebuild the whole model for
#             nothing.
FAILED_REQUIRED=()
FAILED_OPTIONAL=()

collect() {
  local kind="$1" name="$2"; shift 2
  # Running it as an `if` condition is what suppresses set -e for this command.
  if "$@"; then return 0; fi
  echo "  !! collector FAILED (${kind}): ${name}" >&2
  if [[ "$kind" == required ]]; then FAILED_REQUIRED+=("$name")
  else                               FAILED_OPTIONAL+=("$name"); fi
}

# First, because it is the only collector whose window closes behind it.
collect required metrics_exporter \
  "${HERE}/collect/metrics_exporter.py" --project "$PROJECT_ID" --hours "$METRIC_HOURS"

# The sink materialises one table per log id and new ones appear over time.
# Required: every model file below reads v_sink_logs, and a stale union drops a
# whole log source without saying anything.
collect required v_sink_logs \
  python3 "${HERE}/model/build_v_sink_logs.py" --project "$PROJECT_ID"

# Node pool -> instance group hashes, and the reservation id -> name map that
# mlobs_share.v_capacity_daily publishes. Optional *here* only because
# mlobs-poolsnap runs this same script every five minutes; this copy is
# redundancy. A pool missed by both is unresolvable afterwards -- falcon deletes
# its pools inside the job -- so the failure still has to be visible.
collect optional node_pool_snapshot \
  python3 "${HERE}/collect/node_pool_snapshot.py" --project "$PROJECT_ID"

# Last, and optional. Its output does reach fact_event -- 02_dim_mlrun.sql
# builds dim_mlrun and fact_mlrun_event as views over these tables and
# 04_fact_event.sql joins them -- but they are views, so a poll that fails
# leaves the previous state readable rather than leaving a hole. It used to
# run first, where a failure cost the whole model rebuild.
collect optional mldiag_poller \
  "${HERE}/collect/mldiag_poller.py" --project "$PROJECT_ID" \
                                     --locations "$MLDIAG_LOCATIONS" --since-hours 6

echo "=== Model ==="
for f in 00b_dim_config 00c_compact_mldiag 02_dim_mlrun 01_dim_pod 03b_dim_node_pool 03c_jobs_on_target 03d_dim_job_artifact 04_fact_event 04b_fact_incident 06_fact_goodput 07_fact_step 08_views 11_fact_chip 12_chip_hourly 09_fin_utilization; do
  printf "  %-18s " "$f"
  if out=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false \
             < "${HERE}/model/${f}.sql" 2>&1); then
    # `|| true`, because grep exits 1 when it matches nothing and `set -o
    # pipefail` then makes that the pipeline's status, which `set -e` turns into
    # the end of the run. Every model file used to emit at least one
    # Created/Replaced/affected-rows line, so this never fired until
    # 00c_compact_mldiag -- whose whole point is to print nothing on the runs
    # where it decides not to act -- killed two consecutive refreshes at the
    # second file in the loop, with no error message, because the failing
    # command was the summariser and not the query.
    { echo "$out" | grep -Eo '(Created|Replaced|Number of affected rows: [0-9]+)[ a-z._-]*' \
      | tr '\n' ' '; } || true
    echo
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
FROM \`${PROJECT_ID}.mlobs_core.job_hub\`
UNION ALL
SELECT 'fact_step', TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(step_time), MINUTE), COUNT(*)
FROM \`${PROJECT_ID}.mlobs_core.fact_step\`"

if ((${#FAILED_OPTIONAL[@]})); then
  echo "  optional collectors failed, model was rebuilt anyway: ${FAILED_OPTIONAL[*]}" >&2
fi
if ((${#FAILED_REQUIRED[@]})); then
  echo "  required collectors failed: ${FAILED_REQUIRED[*]}" >&2
  exit 1
fi
