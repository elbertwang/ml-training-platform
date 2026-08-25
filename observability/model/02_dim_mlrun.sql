-- dim_mlrun: one row per ML Diagnostics run, latest snapshot wins.
--
-- Demoted from spine to enrichment. Measured coverage of training jobs is
-- 97.5-100%, which is good but not guaranteed: it depends on the poller having
-- run recently, and a stale poll once made a healthy 100% look like 61%. Logs
-- exist for every job unconditionally, so `dim_pod` is the spine and this table
-- is LEFT JOINed onto it.
--
-- `workloadDetails.gke.id` is the K8s workload name and matches dim_pod.job_key
-- for both families -- for JobSets it is the JobSet, not the child Job.

CREATE OR REPLACE VIEW mlobs_core.dim_mlrun AS
WITH latest AS (
  SELECT
    name, location, payload,
    ROW_NUMBER() OVER (PARTITION BY name ORDER BY ingested_at DESC) AS rn
  FROM mlobs_raw.mldiag_runs
)
SELECT
  REGEXP_EXTRACT(name, r'/machineLearningRuns/(.+)$')  AS mlrun_id,
  name                                                  AS mlrun_name,
  location                                              AS mlrun_location,
  JSON_VALUE(payload.displayName)                       AS display_name,
  JSON_VALUE(payload.runPhase)                          AS run_phase,
  JSON_VALUE(payload.orchestrator)                      AS orchestrator,
  JSON_VALUE(payload.workloadDetails.gke.id)            AS job_key,
  JSON_VALUE(payload.workloadDetails.gke.kind)          AS gke_workload_kind,
  REGEXP_EXTRACT(JSON_VALUE(payload.workloadDetails.gke.cluster),
                 r'/clusters/(.+)$')                    AS cluster_name,
  JSON_VALUE(payload.workloadDetails.gke.namespace)     AS namespace_name,
  -- `smon` = discovered by the control plane, so analyzers will run.
  -- `xprof` = created by the SDK, which does NOT get analyzer reports.
  EXISTS(SELECT 1 FROM UNNEST(JSON_QUERY_ARRAY(payload.tools)) t
         WHERE JSON_QUERY(t, '$.smon') IS NOT NULL)     AS has_smon,
  JSON_VALUE(payload.labels.created_by)                 AS created_by,
  mlobs_core.api_ts(JSON_VALUE(payload.createTime))     AS create_time,
  mlobs_core.api_ts(JSON_VALUE(payload.updateTime))     AS update_time,
  mlobs_core.api_ts(JSON_VALUE(payload.endTime))        AS end_time,
  mlobs_core.api_ts(JSON_VALUE(payload.workloadDetails.gke.createTime))
                                                        AS workload_create_time
FROM latest
WHERE rn = 1;


-- fact_mlrun_event: monitored events with analyzer verdicts flattened.
--
-- Each event carries ~9 analyzer reports and almost all say NOT_DETECTED --
-- measured actionable rate is 4.5% for PERFORMANCE_DEGRADATION (184 of 4,113)
-- and 100% for ORCHESTRATOR_INTERRUPTION (14 of 14). `detected_analyzers` keeps
-- the headline on the event row so the timeline never has to unnest.
CREATE OR REPLACE VIEW mlobs_core.fact_mlrun_event AS
WITH latest AS (
  SELECT
    name, run_name, payload,
    ROW_NUMBER() OVER (PARTITION BY name ORDER BY ingested_at DESC) AS rn
  FROM mlobs_raw.mldiag_events
),
events AS (
  SELECT
    REGEXP_EXTRACT(name, r'/monitoredEvents/(.+)$')         AS event_id,
    REGEXP_EXTRACT(run_name, r'/machineLearningRuns/(.+)$') AS mlrun_id,
    JSON_VALUE(payload.type)                                AS event_type,
    JSON_VALUE(payload.displayName)                         AS display_name,
    mlobs_core.api_ts(JSON_VALUE(payload.startTime))        AS start_time,
    mlobs_core.api_ts(JSON_VALUE(payload.endTime))          AS end_time,
    JSON_QUERY_ARRAY(payload.analyzerReports)               AS reports
  FROM latest
  WHERE rn = 1
)
SELECT
  event_id, mlrun_id, event_type, display_name, start_time, end_time,
  TIMESTAMP_DIFF(end_time, start_time, SECOND) AS duration_s,
  ARRAY_LENGTH(reports)                        AS analyzer_count,
  ARRAY(
    SELECT AS STRUCT
      JSON_VALUE(r, '$.analyzer') AS analyzer,
      JSON_VALUE(r, '$.details')  AS details,
      ARRAY(SELECT JSON_VALUE(a, '$.description')
            FROM UNNEST(JSON_QUERY_ARRAY(r, '$.recommendedActions')) a) AS recommended_actions
    FROM UNNEST(reports) r
    WHERE JSON_VALUE(r, '$.detectionState') = 'DETECTED'
  ) AS detected,
  ARRAY_TO_STRING(
    ARRAY(SELECT JSON_VALUE(r, '$.analyzer') FROM UNNEST(reports) r
          WHERE JSON_VALUE(r, '$.detectionState') = 'DETECTED'
          ORDER BY 1), ', ') AS detected_analyzers
FROM events;
