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
# It writes ONE ROW PER POD. That is the whole point and it is not a detail:
# dim_pod unions this table on every rebuild, so its size is paid repeatedly.
# The first version stored one row per matching log entry -- 1,902,302,431 rows
# and 620 GB describing 8,746 distinct pods, a 217,000x redundancy that would
# have cost ~$10,151/month in scan at a 15-minute refresh. Pod labels are
# immutable for the pod's lifetime, so one row each is all dim_pod can use.
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
-- DROP first: an earlier version of this script created the table partitioned
-- by DATE(timestamp), and CREATE OR REPLACE cannot drop a partitioning spec.
DROP TABLE IF EXISTS mlobs_raw.pod_labels_backfill;
CREATE TABLE mlobs_raw.pod_labels_backfill AS
WITH src AS (
  SELECT
    timestamp,
    -- events name the pod only in involvedObject; normalise it into one place
    COALESCE(resource.labels.pod_name,
             IF(JSON_VALUE(json_payload, '\$.involvedObject.kind') = 'Pod',
                JSON_VALUE(json_payload, '\$.involvedObject.name'), NULL)) AS pod_name,
    resource.type                  AS resource_type,
    resource.labels.namespace_name AS namespace_name,
    resource.labels.cluster_name   AS cluster_name,
    resource.labels.location       AS location,
    resource.labels.container_name AS container_name,
    JSON_VALUE(labels, '\$.\"logging.gke.io/top_level_controller_name\"')          AS controller_name,
    JSON_VALUE(labels, '\$.\"logging.gke.io/top_level_controller_type\"')          AS controller_type,
    JSON_VALUE(labels, '\$.\"k8s-pod/jobset_sigs_k8s_io/jobset-name\"')            AS jobset_name,
    JSON_VALUE(labels, '\$.\"k8s-pod/jobset_sigs_k8s_io/restart-attempt\"')        AS restart_attempt,
    JSON_VALUE(labels, '\$.\"k8s-pod/jobset_sigs_k8s_io/job-index\"')              AS job_index,
    JSON_VALUE(labels, '\$.\"k8s-pod/batch_kubernetes_io/controller-uid\"')        AS controller_uid,
    JSON_VALUE(labels, '\$.\"k8s-pod/batch_kubernetes_io/job-completion-index\"')  AS completion_index,
    JSON_VALUE(labels, '\$.\"k8s-pod/owner\"')                                     AS owner,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon-creator\"')                            AS falcon_creator,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon_io/exp-id\"')                          AS falcon_exp_id,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon_io/job-id\"')                          AS falcon_job_id,
    JSON_VALUE(labels, '\$.\"k8s-pod/falcon_io/cluster-id\"')                      AS falcon_cluster_id,
    JSON_VALUE(labels, '\$.\"k8s-pod/primatrix_ai/exp-id\"')                       AS primatrix_exp_id,
    JSON_VALUE(labels, '\$.\"compute.googleapis.com/resource_name\"')              AS node_name
  FROM \`${PROJECT_ID}.defaultLink._AllLogs\`
  WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${DAYS} DAY)
    AND log_id IN ('stdout', 'stderr', 'events')
    AND JSON_VALUE(labels, '\$.\"logging.gke.io/top_level_controller_name\"') IS NOT NULL
)
-- MAX() not ANY_VALUE(): a pod's rows come from several log streams and any one
-- of them may carry NULL for a given label. ANY_VALUE may pick that NULL row;
-- MAX ignores NULLs and so keeps whichever stream actually knew the value.
SELECT
  MIN(timestamp) AS timestamp,
  TO_JSON(STRUCT(
    MAX(resource_type) AS type,
    STRUCT(
      pod_name                   AS pod_name,
      MAX(namespace_name)        AS namespace_name,
      MAX(cluster_name)          AS cluster_name,
      MAX(location)              AS location,
      MAX(container_name)        AS container_name
    ) AS labels
  )) AS resource,
  TO_JSON(STRUCT(
    MAX(controller_name)   AS logging_gke_io_top_level_controller_name,
    MAX(controller_type)   AS logging_gke_io_top_level_controller_type,
    MAX(jobset_name)       AS k8s_pod_jobset_sigs_k8s_io_jobset_name,
    MAX(restart_attempt)   AS k8s_pod_jobset_sigs_k8s_io_restart_attempt,
    MAX(job_index)         AS k8s_pod_jobset_sigs_k8s_io_job_index,
    MAX(controller_uid)    AS k8s_pod_batch_kubernetes_io_controller_uid,
    MAX(completion_index)  AS k8s_pod_batch_kubernetes_io_job_completion_index,
    MAX(owner)             AS k8s_pod_owner,
    MAX(falcon_creator)    AS k8s_pod_falcon_creator,
    MAX(falcon_exp_id)     AS k8s_pod_falcon_io_exp_id,
    MAX(falcon_job_id)     AS k8s_pod_falcon_io_job_id,
    MAX(falcon_cluster_id) AS k8s_pod_falcon_io_cluster_id,
    MAX(primatrix_exp_id)  AS k8s_pod_primatrix_ai_exp_id,
    MAX(node_name)         AS compute_googleapis_com_resource_name
  )) AS labels
FROM src
WHERE pod_name IS NOT NULL
GROUP BY pod_name
"
