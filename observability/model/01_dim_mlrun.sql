-- dim_mlrun: one row per ML Diagnostics run, latest snapshot wins.
--
-- The poller appends a fresh copy of every run on each pass, so this view
-- collapses the history down to the most recently ingested version. Runs are
-- keyed by their resource name; `etag` changes whenever the server mutates the
-- object, which is what makes "latest ingested_at" the right tiebreak.
--
-- `workloadDetails.gke.id` is the K8s Job/JobSet name -- the join key back to
-- pod logs. Prefer it over parsing displayName, which embeds a timestamp
-- suffix and differs between workload families.

CREATE OR REPLACE VIEW `tpu-for-training.mlobs_core.dim_mlrun` AS
WITH latest AS (
  SELECT
    name,
    payload,
    ROW_NUMBER() OVER (PARTITION BY name ORDER BY ingested_at DESC) AS rn
  FROM `tpu-for-training.mlobs_raw.mldiag_runs`
)
SELECT
  REGEXP_EXTRACT(name, r'/machineLearningRuns/(.+)$')     AS mlrun_id,
  name                                                     AS mlrun_name,
  JSON_VALUE(payload.displayName)                          AS display_name,
  JSON_VALUE(payload.runPhase)                             AS run_phase,
  JSON_VALUE(payload.orchestrator)                         AS orchestrator,
  -- workload identity: the join key to pod logs
  JSON_VALUE(payload.workloadDetails.gke.id)               AS gke_workload_name,
  JSON_VALUE(payload.workloadDetails.gke.kind)             AS gke_workload_kind,
  REGEXP_EXTRACT(JSON_VALUE(payload.workloadDetails.gke.cluster),
                 r'/clusters/(.+)$')                       AS cluster_name,
  JSON_VALUE(payload.workloadDetails.gke.namespace)        AS namespace_name,
  -- `smon` means the control plane discovered this run and will run analyzers;
  -- `xprof` means it was created by the SDK and will NOT get analyzer reports.
  EXISTS(SELECT 1 FROM UNNEST(JSON_QUERY_ARRAY(payload.tools)) t
         WHERE JSON_QUERY(t, '$.smon') IS NOT NULL)        AS has_smon,
  JSON_VALUE(payload.labels.created_by)                    AS created_by,
  -- api_ts() trims the API's 9-digit fractional seconds and nulls the
  -- year-0001 sentinel the server returns for runs still in flight.
  `tpu-for-training.mlobs_core.api_ts`(JSON_VALUE(payload.createTime)) AS create_time,
  `tpu-for-training.mlobs_core.api_ts`(JSON_VALUE(payload.updateTime)) AS update_time,
  `tpu-for-training.mlobs_core.api_ts`(JSON_VALUE(payload.endTime))    AS end_time,
  `tpu-for-training.mlobs_core.api_ts`(
      JSON_VALUE(payload.workloadDetails.gke.createTime))              AS workload_create_time
FROM latest
WHERE rn = 1;
