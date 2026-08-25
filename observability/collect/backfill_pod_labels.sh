#!/bin/bash
# One-off: materialise pod->job labels from before the sink existed.
#
# A Log Router sink is not retroactive, so on a fresh install dim_pod only knows
# about pods that have logged since deploy.sh ran. This reads the same labels
# out of the Log Analytics linked dataset for a bounded window and stores them
# in `mlobs_raw.pod_labels_backfill`, which dim_pod unions with the live sink.
#
# It is deliberately a separate, manual step rather than part of the model.
# Reading `labels` from defaultLink is the expensive access pattern the whole
# architecture is built to avoid -- 303 GB per day of data in tpu-for-training,
# 36 GB/day in the playground project. Materialising once costs that once;
# putting it in the model would cost it on every rebuild.
#
#   DAYS=7 PROJECT_ID=tpu-launchpad-playground ./backfill_pod_labels.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
DAYS="${DAYS:-7}"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

SQL="
-- Key names differ between the two surfaces and this is easy to miss: the
-- BigQuery sink sanitises label keys (logging.gke.io/top_level_controller_name
-- becomes logging_gke_io_top_level_controller_name) while the Log Analytics
-- linked dataset keeps them verbatim, dots and slashes included. dim_pod reads
-- the sanitised form, so the backfill has to translate. A first version did
-- not, and silently produced zero rows.
CREATE OR REPLACE TABLE mlobs_raw.pod_labels_backfill
PARTITION BY DATE(timestamp)
AS
SELECT
  timestamp,
  TO_JSON(resource) AS resource,
  TO_JSON(STRUCT(
    JSON_VALUE(labels, '\$.\"logging.gke.io/top_level_controller_name\"')          AS logging_gke_io_top_level_controller_name,
    JSON_VALUE(labels, '\$.\"logging.gke.io/top_level_controller_type\"')          AS logging_gke_io_top_level_controller_type,
    JSON_VALUE(labels, '\$.\"k8s-pod/jobset_sigs_k8s_io/jobset-name\"')            AS k8s_pod_jobset_sigs_k8s_io_jobset_name,
    JSON_VALUE(labels, '\$.\"k8s-pod/jobset_sigs_k8s_io/restart-attempt\"')        AS k8s_pod_jobset_sigs_k8s_io_restart_attempt,
    JSON_VALUE(labels, '\$.\"k8s-pod/jobset_sigs_k8s_io/job-index\"')              AS k8s_pod_jobset_sigs_k8s_io_job_index,
    JSON_VALUE(labels, '\$.\"k8s-pod/batch_kubernetes_io/controller-uid\"')        AS k8s_pod_batch_kubernetes_io_controller_uid,
    JSON_VALUE(labels, '\$.\"k8s-pod/batch_kubernetes_io/job-completion-index\"')  AS k8s_pod_batch_kubernetes_io_job_completion_index,
    JSON_VALUE(labels, '\$.\"k8s-pod/owner\"')                                     AS k8s_pod_owner,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon-creator\"')                            AS k8s_pod_falcon_creator,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon_io/exp-id\"')                          AS k8s_pod_falcon_io_exp_id,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon_io/job-id\"')                          AS k8s_pod_falcon_io_job_id,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon_io/cluster-id\"')                      AS k8s_pod_falcon_io_cluster_id,
    JSON_VALUE(labels, '\$.\"k8s-pod/primatrix_ai/exp-id\"')                       AS k8s_pod_primatrix_ai_exp_id,
    JSON_VALUE(labels, '\$.\"compute.googleapis.com/resource_name\"')              AS compute_googleapis_com_resource_name
  )) AS labels
FROM \`${PROJECT_ID}.defaultLink._AllLogs\`
WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${DAYS} DAY)
  AND log_id IN ('stdout', 'stderr')
  AND JSON_VALUE(labels, '\$.\"logging.gke.io/top_level_controller_name\"') IS NOT NULL
"

echo "Estimating scan for ${DAYS} day(s) in ${PROJECT_ID} ..."
bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --dry_run "$SQL" 2>&1 \
  | grep -oE 'of [0-9]+ bytes' | grep -oE '[0-9]+' \
  | awk '{printf "  %.1f GB  (~$%.2f at $6.25/TiB on-demand)\n", $1/1e9, $1/1099511627776*6.25}'

bq --project_id="$PROJECT_ID" query --use_legacy_sql=false "$SQL" >/dev/null
ROWS=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv \
       "SELECT COUNT(*) FROM mlobs_raw.pod_labels_backfill" 2>/dev/null | tail -1)
echo "  pod_labels_backfill: ${ROWS} rows"
echo "  now re-run: bq --project_id=${PROJECT_ID} query --use_legacy_sql=false < model/01_dim_pod.sql"
