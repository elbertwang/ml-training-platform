-- dim_pod: the authoritative pod -> job mapping, and the spine of the model.
--
-- Everything else joins through this. Cloud Monitoring only ever labels a
-- series with `pod_name`, and pod names cannot be parsed reliably (see the
-- comment on job_key_from_pod_fallback), so the mapping comes from the GKE
-- labels Cloud Logging attaches to every container log line. Measured coverage
-- of `logging.gke.io/top_level_controller_name` in the training namespaces of
-- tpu-for-training is 100%.
--
-- Two keys, because they answer different questions:
--
--   job_key      the job as a human names it. For JobSet workloads this is the
--                JobSet, NOT the child Job: top_level_controller_name gives
--                "<jobset>-worker-0" while ML Diagnostics reports the workload
--                as "<jobset>". Using the child name breaks every join to
--                dim_mlrun.
--   attempt_uid  one Job object = one attempt. Names get reused --
--                "henry-hlo-test" is 101 distinct runs over seven weeks -- so
--                anything keyed on job_key alone silently merges them.
--
-- Sources are stdout, stderr AND `events`, which matters more than it looks.
-- The sink deliberately keeps only ERROR+ and `completed step` lines, so a
-- healthy job that logs neither produces nothing for the model to see -- the
-- k3run-r JobSet in the playground project was running on TPUs, reporting
-- metrics, and completely invisible here until events were added. Every pod
-- gets Kubernetes events (scheduled, pulling, started) whatever it writes to
-- stdout, and those events carry the same controller labels, so events are the
-- reliable spine and container logs are the enrichment.
--
-- Reads v_sink_logs rather than the linked dataset. Selecting `labels` for the
-- stdout/stderr branches scans ~813 MB of accumulated sink data; the same
-- column on defaultLink is ~303 GB per day. Both `resource` and `labels` are
-- JSON there because struct field sets differ per log table -- JSON_VALUE
-- returns NULL for keys a project does not have, which is what lets one model
-- deploy to projects with different label sets.

CREATE OR REPLACE TABLE mlobs_core.dim_pod
PARTITION BY DATE(first_seen)
CLUSTER BY job_key, pod_name
AS
WITH src AS (
  -- live: everything the sink has delivered since it was created
  SELECT
    timestamp,
    -- an event about a pod may carry the pod only in involvedObject
    CASE WHEN JSON_VALUE(resource, '$.labels.pod_name') IS NULL
              AND JSON_VALUE(json_payload, '$.involvedObject.kind') = 'Pod'
         THEN JSON_SET(resource, '$.labels.pod_name',
                       JSON_VALUE(json_payload, '$.involvedObject.name'))
         ELSE resource END AS resource,
    labels
  FROM mlobs_core.v_sink_logs
  WHERE log_id IN ('stdout', 'stderr', 'events')
    AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  UNION ALL
  -- history: a sink is not retroactive, so pods that ran before it existed are
  -- only known through a one-off materialisation from the linked dataset.
  -- Empty until collect/backfill_pod_labels.sh is run.
  SELECT timestamp, resource, labels
  FROM mlobs_raw.pod_labels_backfill
),
tagged AS (
  SELECT
    JSON_VALUE(resource, '$.labels.pod_name')       AS pod_name,
    JSON_VALUE(resource, '$.labels.namespace_name') AS namespace_name,
    JSON_VALUE(resource, '$.labels.cluster_name')   AS cluster_name,
    JSON_VALUE(resource, '$.labels.location')       AS location,
    JSON_VALUE(resource, '$.labels.container_name') AS container_name,
    JSON_VALUE(labels, '$.logging_gke_io_top_level_controller_name') AS controller_name,
    JSON_VALUE(labels, '$.logging_gke_io_top_level_controller_type') AS controller_type,
    JSON_VALUE(labels, '$.k8s_pod_jobset_sigs_k8s_io_jobset_name')   AS jobset_name,
    JSON_VALUE(labels, '$.k8s_pod_batch_kubernetes_io_controller_uid') AS attempt_uid,
    JSON_VALUE(labels, '$.k8s_pod_batch_kubernetes_io_job_completion_index') AS completion_index,
    JSON_VALUE(labels, '$.k8s_pod_jobset_sigs_k8s_io_restart_attempt') AS jobset_restart_attempt,
    JSON_VALUE(labels, '$.k8s_pod_jobset_sigs_k8s_io_job_index')     AS jobset_job_index,
    -- ownership: falcon publishes these, other families do not
    COALESCE(JSON_VALUE(labels, '$.k8s_pod_owner'),
             JSON_VALUE(labels, '$.k8s_pod_falcon_creator'))         AS owner,
    COALESCE(JSON_VALUE(labels, '$.k8s_pod_falcon_io_exp_id'),
             JSON_VALUE(labels, '$.k8s_pod_primatrix_ai_exp_id'))    AS exp_id,
    JSON_VALUE(labels, '$.k8s_pod_falcon_io_job_id')                 AS falcon_job_id,
    JSON_VALUE(labels, '$.k8s_pod_falcon_io_cluster_id')             AS falcon_cluster_id,
    JSON_VALUE(labels, '$.compute_googleapis_com_resource_name')     AS node_name,
    timestamp
  FROM src
)
SELECT
  pod_name,
  MAX(namespace_name) AS namespace_name,
  MAX(cluster_name)   AS cluster_name,
  MAX(location)       AS location,
  -- JobSet first: it is what ML Diagnostics calls the workload
  COALESCE(MAX(jobset_name), MAX(controller_name)) AS job_key,
  MAX(controller_name) AS child_job_name,
  MAX(controller_type) AS controller_type,
  CASE
    WHEN MAX(jobset_name) IS NOT NULL                        THEN 'jobset'
    WHEN STARTS_WITH(MAX(controller_name), 'falcon-job')     THEN 'falcon'
    ELSE LOWER(COALESCE(MAX(controller_type), 'unknown'))
  END                        AS job_family,
  -- MAX rather than ANY_VALUE throughout: with three log sources unioned, a
  -- pod's labels are present in some rows and absent in others, and ANY_VALUE
  -- may return the NULL.
  -- controller_uid exists only on Job-owned pods. Deployment/DaemonSet/
  -- StatefulSet pods have no notion of an attempt, so fall back to the
  -- controller name: those workloads then have exactly one "attempt", which is
  -- the right answer. Filtering on uid instead left dim_job_attempt empty.
  COALESCE(MAX(attempt_uid), MAX(controller_name)) AS attempt_uid,
  MAX(attempt_uid) IS NOT NULL                           AS is_job_attempt,
  SAFE_CAST(MAX(completion_index) AS INT64)       AS completion_index,
  SAFE_CAST(MAX(jobset_restart_attempt) AS INT64) AS jobset_restart_attempt,
  SAFE_CAST(MAX(jobset_job_index) AS INT64)       AS jobset_job_index,
  MAX(owner)             AS owner,
  MAX(exp_id)            AS exp_id,
  MAX(falcon_job_id)     AS falcon_job_id,
  MAX(falcon_cluster_id) AS falcon_cluster_id,
  MAX(node_name)         AS node_name,
  ARRAY_AGG(DISTINCT container_name IGNORE NULLS) AS containers,
  MIN(timestamp)               AS first_seen,
  MAX(timestamp)               AS last_seen
FROM tagged
WHERE pod_name IS NOT NULL
  AND controller_name IS NOT NULL   -- system pods with no controller are not jobs
GROUP BY pod_name;
