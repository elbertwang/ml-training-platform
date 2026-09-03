-- fact_incident: infrastructure events as lifecycles, and which jobs they hit.
--
-- fact_event records what a log line said. This records what happened: an
-- upgrade that started at 19:24 and was cancelled at 20:28 is one incident with
-- an outcome, not two unrelated rows. The distinction is not cosmetic --
-- "did this upgrade finish or get rolled back" is the question, and a table of
-- atoms cannot answer it without the reader re-deriving the pairing every time.
--
-- Built from v_sink_logs rather than from fact_event. fact_event has fourteen
-- fixed columns and no room for an incident key, and squeezing one in made a
-- column mean two things. Both tables read L1 and answer different questions.
--
-- Three shapes arrive, and all three had to be handled explicitly because
-- assuming one shape silently drops the others:
--
--   maintenance  a state machine keyed by resourceMaintenances/<uuid>:
--                RUNNING -> SUCCEEDED | CANCELLED. SERVICE_UPDATE targets a
--                node pool, INFRASTRUCTURE targets one VM.
--   gke_op       an audit operation keyed by operation.id, with a NOTICE row at
--                operation.first and another at operation.last. AUTO_REPAIR_NODES
--                appears here as ClusterManagerInternal.RepairNodePool.
--   node_repair  a managed instance group recreating one VM. first and last are
--                both true on the same row -- it is instantaneous, so start and
--                end coincide, and modelling it as an interval would have
--                produced a NULL end forever.
--
-- **Only one side may be present.** Measured on a one-day window: several
-- operations showed operation.last with no operation.first, because they began
-- before the window. An incident builder that requires both drops those; this
-- one records ended_at without started_at and says so through `state`.

CREATE OR REPLACE TABLE mlobs_core.fact_incident
CLUSTER BY kind, target
AS
WITH maint AS (
  SELECT
    JSON_VALUE(json_payload, '$.name')                          AS incident_uid,
    'maintenance'                                               AS kind,
    JSON_VALUE(json_payload, '$.maintenance.category')          AS category,
    ANY_VALUE(JSON_VALUE(json_payload, '$.maintenance.title'))  AS title,
    IF(JSON_VALUE(json_payload, '$.maintenance.category') = 'SERVICE_UPDATE',
       'node_pool', 'node')                                     AS target_kind,
    ANY_VALUE(COALESCE(
      JSON_VALUE(resource, '$.labels.nodepool_name'),
      REGEXP_EXTRACT(JSON_VALUE(json_payload, '$.resource.resourceName'),
                     r'/instances/([^/]+)$')))                  AS target,
    MIN(IF(JSON_VALUE(json_payload, '$.state') = 'RUNNING', timestamp, NULL)) AS started_at,
    MAX(IF(JSON_VALUE(json_payload, '$.state') IN ('SUCCEEDED', 'CANCELLED', 'FAILED'),
           timestamp, NULL))                                    AS ended_at,
    ARRAY_AGG(JSON_VALUE(json_payload, '$.state')
              ORDER BY timestamp DESC LIMIT 1)[OFFSET(0)]       AS state,
    CAST(NULL AS STRING)                                        AS reason,
    COUNT(*)                                                    AS log_entries,
    ANY_VALUE(JSON_VALUE(resource, '$.labels.cluster_name'))    AS cluster_name
  FROM mlobs_core.v_sink_logs
  WHERE log_id = 'maintenance_googleapis_com_maintenance_events'
  GROUP BY incident_uid, kind, category, target_kind
),
ops AS (
  SELECT
    JSON_VALUE(operation, '$.id')                               AS incident_uid,
    IF(JSON_VALUE(proto_payload, '$.methodName') LIKE '%RepairNodePool',
       'node_repair_pool', 'gke_op')                            AS kind,
    REGEXP_EXTRACT(ANY_VALUE(JSON_VALUE(proto_payload, '$.methodName')),
                   r'([^.]+)$')                                 AS category,
    ANY_VALUE(JSON_VALUE(proto_payload, '$.methodName'))        AS title,
    'node_pool'                                                 AS target_kind,
    ANY_VALUE(REGEXP_EXTRACT(JSON_VALUE(proto_payload, '$.resourceName'),
                             r'/nodePools/([^/]+)$'))           AS target,
    MIN(IF(JSON_VALUE(operation, '$.first') = 'true', timestamp, NULL)) AS started_at,
    MAX(IF(JSON_VALUE(operation, '$.last')  = 'true', timestamp, NULL)) AS ended_at,
    -- No explicit state in the audit log; derive it from the closing entry
    -- only. "Any row had severity ERROR" looks equivalent and is not: falcon
    -- retries a delete against a busy cluster hundreds of times, every
    -- rejection is an ERROR row, and the operation then succeeds. Judging on
    -- the whole set marked all 83 operations FAILED on the first build.
    CASE
      WHEN MAX(IF(JSON_VALUE(operation, '$.last') = 'true', 1, 0)) = 0 THEN 'RUNNING'
      WHEN MAX(IF(JSON_VALUE(operation, '$.last') = 'true'
                  AND severity = 'ERROR', 1, 0)) = 1                   THEN 'FAILED'
      ELSE 'SUCCEEDED'
    END                                                         AS state,
    -- The reason it ended the way it did: GCE_STOCKOUT, reservation capacity,
    -- an instance-group timeout. This is the column that explains why a
    -- maintenance incident turns CANCELLED a fraction of a second later. Taken
    -- from the closing entry for the same reason as the state -- ANY_VALUE here
    -- would return one of the interchangeable retry rejections instead.
    ARRAY_AGG(NULLIF(JSON_VALUE(proto_payload, '$.status.message'), '') IGNORE NULLS
              ORDER BY IF(JSON_VALUE(operation, '$.last') = 'true', 1, 0) DESC,
                       timestamp DESC LIMIT 1)[SAFE_OFFSET(0)]  AS reason,
    -- How many raw entries this operation produced. A four-figure count is
    -- itself the finding: it means something is hammering the API.
    COUNT(*)                                                    AS log_entries,
    ANY_VALUE(JSON_VALUE(resource, '$.labels.cluster_name'))    AS cluster_name
  FROM mlobs_core.v_sink_logs
  WHERE log_id = 'cloudaudit_googleapis_com_activity'
    AND JSON_VALUE(proto_payload, '$.serviceName') = 'container.googleapis.com'
    AND JSON_VALUE(operation, '$.id') IS NOT NULL
  GROUP BY incident_uid, kind
),
repairs AS (
  SELECT
    JSON_VALUE(operation, '$.id')                               AS incident_uid,
    'node_repair'                                               AS kind,
    REGEXP_EXTRACT(ANY_VALUE(JSON_VALUE(proto_payload, '$.methodName')),
                   r'([^.]+)$')                                 AS category,
    ANY_VALUE(JSON_VALUE(proto_payload, '$.methodName'))        AS title,
    'node'                                                      AS target_kind,
    ANY_VALUE(REGEXP_EXTRACT(JSON_VALUE(proto_payload, '$.resourceName'),
                             r'/instances/([^/]+)$'))           AS target,
    MIN(timestamp) AS started_at,
    MAX(timestamp) AS ended_at,
    'SUCCEEDED'    AS state,
    CAST(NULL AS STRING) AS reason,
    COUNT(*)             AS log_entries,
    ANY_VALUE(JSON_VALUE(resource, '$.labels.cluster_name'))    AS cluster_name
  FROM mlobs_core.v_sink_logs
  WHERE log_id = 'cloudaudit_googleapis_com_system_event'
    AND JSON_VALUE(proto_payload, '$.methodName') LIKE 'compute.instances.%'
  GROUP BY incident_uid, kind
),
all_inc AS (
  SELECT * FROM maint UNION ALL SELECT * FROM ops UNION ALL SELECT * FROM repairs
)
SELECT
  i.incident_uid,
  i.kind,
  i.category,
  i.title,
  i.target_kind,
  i.target,
  i.cluster_name,
  i.state,
  i.reason,
  i.log_entries,
  i.started_at,
  i.ended_at,
  COALESCE(i.started_at, i.ended_at) AS occurred_at,
  TIMESTAMP_DIFF(i.ended_at, i.started_at, SECOND) AS duration_s,
  -- Which jobs were on the target while this was happening. A window of one
  -- hour either side, because a pod's dim_pod row bounds when it logged, not
  -- when it was scheduled, and an upgrade drains nodes before the log stops.
  ARRAY(
    SELECT AS STRUCT j.job_key, j.pods, j.namespace_name
    FROM mlobs_core.jobs_on_target(
           i.target_kind, i.target,
           TIMESTAMP_SUB(COALESCE(i.started_at, i.ended_at), INTERVAL 1 HOUR),
           TIMESTAMP_ADD(COALESCE(i.ended_at, i.started_at), INTERVAL 1 HOUR)) j
  ) AS affected_jobs
FROM all_inc i
WHERE i.target IS NOT NULL;
