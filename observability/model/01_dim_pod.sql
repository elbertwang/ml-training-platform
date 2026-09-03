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

-- **Accumulated with MERGE, and never trimmed.** Two reasons, and they arrived
-- from opposite directions.
--
-- Cost: the rebuild read a 30-day window of v_sink_logs, so its price tracked
-- however much log data had piled up. Measured on the same day, the full
-- rebuild scanned 20.9 GB and this MERGE scans 0.418 GB -- at a 30-minute
-- cadence that is $188/month against $3.8/month, and the gap widens every day
-- the sink runs. (An earlier comment in schedule/deploy.sh quotes 3.6 GB; that
-- was measured when the sink held two days of data.)
--
-- Correctness: a 30-day rolling rebuild forgets. Pods older than the window
-- vanished from the table even though nothing had gone wrong, which made "which
-- job held these nodes last quarter" unanswerable by construction. Rows are now
-- kept forever -- 3,800 pods a day, 308 bytes each, so a year is 426 MB and
-- about a cent a month of storage.
--
-- Identity fields only ever move upward. This is subtle and it bit during the
-- conversion: the source computes job_key as COALESCE(jobset_name,
-- controller_name) and attempt_uid as COALESCE(controller_uid,
-- controller_name), so neither is ever NULL, and a plain COALESCE(source,
-- target) in the UPDATE cannot distinguish a real label from a fallback. A
-- narrow window that happened to miss the label would overwrite a good value
-- with the fallback -- for a JobSet pod that means job_key silently becoming
-- "<jobset>-worker-0", which is exactly the value the header above warns
-- against. Reconciling the merged table against a full rebuild found four
-- falcon pods whose controller-uid had been replaced by the controller name.
-- The UPDATE clause therefore reads the raw nullable labels, not the
-- fallbacks, and the fallback is applied only when inserting a new row.
--
-- The window is three hours against a 30-minute refresh: six times the overlap
-- needed, at the same cost as two hours because the dry-run prices by
-- partition. A fresh project starts with whatever the window covers and grows
-- from there; use collect/backfill_pod_labels.sh to seed history.

CREATE TABLE IF NOT EXISTS mlobs_core.dim_pod
(
  pod_name               STRING,
  namespace_name         STRING,
  cluster_name           STRING,
  location               STRING,
  job_key                STRING,
  child_job_name         STRING,
  controller_type        STRING,
  job_family             STRING,
  attempt_uid            STRING,
  is_job_attempt         BOOL,
  completion_index       INT64,
  jobset_restart_attempt INT64,
  jobset_job_index       INT64,
  owner                  STRING,
  exp_id                 STRING,
  falcon_job_id          STRING,
  falcon_cluster_id      STRING,
  node_name              STRING,
  containers             ARRAY<STRING>,
  first_seen             TIMESTAMP,
  last_seen              TIMESTAMP
)
PARTITION BY DATE(first_seen)
CLUSTER BY job_key, pod_name;

MERGE mlobs_core.dim_pod T
USING (
  WITH src AS (
    SELECT timestamp,
      CASE WHEN JSON_VALUE(resource, '$.labels.pod_name') IS NULL
                AND JSON_VALUE(json_payload, '$.involvedObject.kind') = 'Pod'
           THEN JSON_SET(resource, '$.labels.pod_name',
                         JSON_VALUE(json_payload, '$.involvedObject.name'))
           ELSE resource END AS resource,
      labels
    FROM mlobs_core.v_sink_logs
    WHERE log_id IN ('stdout', 'stderr', 'events')
      AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 HOUR)
    UNION ALL
    SELECT timestamp, resource, labels FROM mlobs_raw.pod_labels_backfill
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
    MAX(jobset_name)     AS jobset_name,
    COALESCE(MAX(jobset_name), MAX(controller_name)) AS job_key,
    MAX(controller_name) AS child_job_name,
    MAX(controller_type) AS controller_type,
    CASE
      WHEN MAX(jobset_name) IS NOT NULL                    THEN 'jobset'
      WHEN STARTS_WITH(MAX(controller_name), 'falcon-job') THEN 'falcon'
      WHEN MAX(controller_type) IS NOT NULL                THEN LOWER(MAX(controller_type))
      ELSE NULL
    END AS job_family,
    MAX(attempt_uid) AS attempt_uid_raw,
    COALESCE(MAX(attempt_uid), MAX(controller_name)) AS attempt_uid,
    MAX(attempt_uid) IS NOT NULL                     AS is_job_attempt,
    SAFE_CAST(MAX(completion_index) AS INT64)        AS completion_index,
    SAFE_CAST(MAX(jobset_restart_attempt) AS INT64)  AS jobset_restart_attempt,
    SAFE_CAST(MAX(jobset_job_index) AS INT64)        AS jobset_job_index,
    MAX(owner) AS owner, MAX(exp_id) AS exp_id,
    MAX(falcon_job_id) AS falcon_job_id, MAX(falcon_cluster_id) AS falcon_cluster_id,
    MAX(node_name) AS node_name,
    ARRAY_AGG(DISTINCT container_name IGNORE NULLS) AS containers,
    MIN(timestamp) AS first_seen, MAX(timestamp) AS last_seen
  FROM tagged
  WHERE pod_name IS NOT NULL AND controller_name IS NOT NULL
  GROUP BY pod_name
) S
ON T.pod_name = S.pod_name
WHEN MATCHED THEN UPDATE SET
  first_seen = LEAST(T.first_seen, S.first_seen),
  last_seen  = GREATEST(T.last_seen, S.last_seen),
  namespace_name = COALESCE(S.namespace_name, T.namespace_name),
  cluster_name   = COALESCE(S.cluster_name,   T.cluster_name),
  location       = COALESCE(S.location,       T.location),
  -- Identity fields only ever move upward, never down. The source's own
  -- COALESCE fallbacks are never NULL, so a plain COALESCE(S, T) cannot tell a
  -- real label from a fallback and would overwrite a good value with the
  -- fallback whenever a narrow window happens to miss the label. Caught by
  -- reconciling against the full rebuild: 4 falcon pods had their real
  -- controller-uid replaced by the controller name.
  job_key        = COALESCE(S.jobset_name,     T.job_key),
  child_job_name = COALESCE(S.child_job_name, T.child_job_name),
  controller_type= COALESCE(S.controller_type,T.controller_type),
  job_family     = IF(S.jobset_name IS NOT NULL, 'jobset', T.job_family),
  attempt_uid    = COALESCE(S.attempt_uid_raw, T.attempt_uid),
  is_job_attempt = T.is_job_attempt OR S.is_job_attempt,
  completion_index = COALESCE(S.completion_index, T.completion_index),
  jobset_restart_attempt = COALESCE(S.jobset_restart_attempt, T.jobset_restart_attempt),
  jobset_job_index = COALESCE(S.jobset_job_index, T.jobset_job_index),
  owner = COALESCE(S.owner, T.owner),
  exp_id = COALESCE(S.exp_id, T.exp_id),
  falcon_job_id = COALESCE(S.falcon_job_id, T.falcon_job_id),
  falcon_cluster_id = COALESCE(S.falcon_cluster_id, T.falcon_cluster_id),
  node_name = COALESCE(S.node_name, T.node_name),
  -- A pod's container set is fixed when it is created, so the two arrays
  -- differ only when one window saw fewer of them. Keep the fuller
  -- observation. A correlated subquery would dedupe a concat properly but
  -- BigQuery does not allow one in an UPDATE clause.
  containers = IF(ARRAY_LENGTH(S.containers) >= ARRAY_LENGTH(T.containers),
                  S.containers, T.containers)
WHEN NOT MATCHED THEN INSERT
  (pod_name, namespace_name, cluster_name, location, job_key, child_job_name,
   controller_type, job_family, attempt_uid, is_job_attempt, completion_index,
   jobset_restart_attempt, jobset_job_index, owner, exp_id, falcon_job_id,
   falcon_cluster_id, node_name, containers, first_seen, last_seen)
VALUES
  (S.pod_name, S.namespace_name, S.cluster_name, S.location, S.job_key,
   S.child_job_name, S.controller_type, COALESCE(S.job_family, 'unknown'),
   S.attempt_uid, S.is_job_attempt, S.completion_index, S.jobset_restart_attempt,
   S.jobset_job_index, S.owner, S.exp_id, S.falcon_job_id, S.falcon_cluster_id,
   S.node_name, S.containers, S.first_seen, S.last_seen);
