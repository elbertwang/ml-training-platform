#!/bin/bash
# One-off repair: collapse pod_labels_backfill to one row per pod.
#
# The first version of backfill_pod_labels.sh stored every matching log entry
# instead of the distinct pod->label mapping: 1,902,302,431 rows and 620 GB
# describing 8,746 pods. dim_pod unions this table on every rebuild, so the
# redundancy is re-scanned each time -- $3.49 per rebuild, and refresh.sh is
# about to go on a 15-minute schedule.
#
# backfill_pod_labels.sh is fixed, but re-running it would re-read 7 days of
# defaultLink._AllLogs (~2.1 TB, ~$13). Deduplicating the existing table in
# place reads 620 GB (~$3.88) and produces exactly the same result, without
# depending on how far back Log Analytics retention still reaches.
#
# Run once per project, then delete this script.
#
#   PROJECT_ID=tpu-for-training ./dedupe_pod_labels_backfill.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

# Same aggregation as the fixed backfill_pod_labels.sh, so both paths produce an
# identical schema. MAX() not ANY_VALUE(): a pod's rows come from several log
# streams and any one of them may carry NULL for a given label; ANY_VALUE may
# pick that NULL row, MAX ignores NULLs.
# Built into a staging table first, then swapped. Two reasons: the old table is
# day-partitioned and the new one has no reason to be (8,746 rows), and
# CREATE OR REPLACE refuses to change a partitioning spec; and a staging table
# means a failed query leaves the original intact.
SQL="
CREATE OR REPLACE TABLE \`${PROJECT_ID}.mlobs_raw.pod_labels_backfill_staging\` AS
WITH src AS (
  SELECT
    timestamp,
    JSON_VALUE(resource, '\$.labels.pod_name')       AS pod_name,
    JSON_VALUE(resource, '\$.type')                  AS resource_type,
    JSON_VALUE(resource, '\$.labels.namespace_name') AS namespace_name,
    JSON_VALUE(resource, '\$.labels.cluster_name')   AS cluster_name,
    JSON_VALUE(resource, '\$.labels.location')       AS location,
    JSON_VALUE(resource, '\$.labels.container_name') AS container_name,
    labels
  FROM \`${PROJECT_ID}.mlobs_raw.pod_labels_backfill\`
)
SELECT
  MIN(timestamp) AS timestamp,
  TO_JSON(STRUCT(
    MAX(resource_type) AS type,
    STRUCT(
      pod_name            AS pod_name,
      MAX(namespace_name) AS namespace_name,
      MAX(cluster_name)   AS cluster_name,
      MAX(location)       AS location,
      MAX(container_name) AS container_name
    ) AS labels
  )) AS resource,
  TO_JSON(STRUCT(
    MAX(JSON_VALUE(labels, '\$.logging_gke_io_top_level_controller_name'))         AS logging_gke_io_top_level_controller_name,
    MAX(JSON_VALUE(labels, '\$.logging_gke_io_top_level_controller_type'))         AS logging_gke_io_top_level_controller_type,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_jobset_sigs_k8s_io_jobset_name'))           AS k8s_pod_jobset_sigs_k8s_io_jobset_name,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_jobset_sigs_k8s_io_restart_attempt'))       AS k8s_pod_jobset_sigs_k8s_io_restart_attempt,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_jobset_sigs_k8s_io_job_index'))             AS k8s_pod_jobset_sigs_k8s_io_job_index,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_batch_kubernetes_io_controller_uid'))       AS k8s_pod_batch_kubernetes_io_controller_uid,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_batch_kubernetes_io_job_completion_index')) AS k8s_pod_batch_kubernetes_io_job_completion_index,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_owner'))                                    AS k8s_pod_owner,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_falcon_creator'))                           AS k8s_pod_falcon_creator,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_falcon_io_exp_id'))                         AS k8s_pod_falcon_io_exp_id,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_falcon_io_job_id'))                         AS k8s_pod_falcon_io_job_id,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_falcon_io_cluster_id'))                     AS k8s_pod_falcon_io_cluster_id,
    MAX(JSON_VALUE(labels, '\$.k8s_pod_primatrix_ai_exp_id'))                      AS k8s_pod_primatrix_ai_exp_id,
    MAX(JSON_VALUE(labels, '\$.compute_googleapis_com_resource_name'))             AS compute_googleapis_com_resource_name
  )) AS labels
FROM src
WHERE pod_name IS NOT NULL
GROUP BY pod_name
"

echo "== dry run =="
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --dry_run "${SQL}"

echo "== running =="
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --nouse_cache "${SQL}"

echo "== verifying staging before swap =="
STAGED=$(bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=csv \
  "SELECT COUNT(*) FROM \`${PROJECT_ID}.mlobs_raw.pod_labels_backfill_staging\`" | tail -1)
if [[ "${STAGED}" -lt 1 ]]; then
  echo "staging table is empty -- leaving the original alone" >&2
  exit 1
fi
echo "staging has ${STAGED} rows"

echo "== swapping =="
bq --project_id="${PROJECT_ID}" rm -f -t "${PROJECT_ID}:mlobs_raw.pod_labels_backfill"
bq --project_id="${PROJECT_ID}" cp -f \
  "${PROJECT_ID}:mlobs_raw.pod_labels_backfill_staging" \
  "${PROJECT_ID}:mlobs_raw.pod_labels_backfill"
bq --project_id="${PROJECT_ID}" rm -f -t "${PROJECT_ID}:mlobs_raw.pod_labels_backfill_staging"

echo "== after =="
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=pretty \
  "SELECT COUNT(*) AS rows_after,
          COUNT(DISTINCT JSON_VALUE(resource, '\$.labels.pod_name')) AS distinct_pods,
          COUNTIF(JSON_VALUE(labels, '\$.logging_gke_io_top_level_controller_name') IS NULL) AS missing_controller
   FROM \`${PROJECT_ID}.mlobs_raw.pod_labels_backfill\`"
