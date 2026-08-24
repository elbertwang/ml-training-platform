-- fact_mlrun_event: one row per ML Diagnostics monitored event, with the
-- analyzer verdicts both flattened (for drill-down) and summarised (for the
-- unified timeline).
--
-- An event carries ~9 analyzer reports, almost all NOT_DETECTED. The value is
-- in the one or two that fire: they name the subsystem, the blast radius and
-- the recommended next action. `detected_analyzers` keeps that headline on the
-- event row so the timeline does not have to unnest.

CREATE OR REPLACE VIEW `tpu-for-training.mlobs_core.fact_mlrun_event` AS
WITH latest AS (
  SELECT
    name, run_name, payload,
    ROW_NUMBER() OVER (PARTITION BY name ORDER BY ingested_at DESC) AS rn
  FROM `tpu-for-training.mlobs_raw.mldiag_events`
),
events AS (
  SELECT
    REGEXP_EXTRACT(name, r'/monitoredEvents/(.+)$')          AS event_id,
    REGEXP_EXTRACT(run_name, r'/machineLearningRuns/(.+)$')  AS mlrun_id,
    JSON_VALUE(payload.type)                                  AS event_type,
    JSON_VALUE(payload.displayName)                           AS display_name,
    `tpu-for-training.mlobs_core.api_ts`(JSON_VALUE(payload.startTime)) AS start_time,
    `tpu-for-training.mlobs_core.api_ts`(JSON_VALUE(payload.endTime))   AS end_time,
    JSON_QUERY_ARRAY(payload.analyzerReports)                 AS reports
  FROM latest
  WHERE rn = 1
)
SELECT
  e.event_id,
  e.mlrun_id,
  e.event_type,
  e.display_name,
  e.start_time,
  e.end_time,
  TIMESTAMP_DIFF(e.end_time, e.start_time, SECOND)            AS duration_s,
  ARRAY_LENGTH(e.reports)                                     AS analyzer_count,
  -- the analyzers that actually fired, with their finding and advice attached
  ARRAY(
    SELECT AS STRUCT
      JSON_VALUE(r, '$.analyzer')                             AS analyzer,
      JSON_VALUE(r, '$.details')                              AS details,
      ARRAY(SELECT JSON_VALUE(a, '$.description')
            FROM UNNEST(JSON_QUERY_ARRAY(r, '$.recommendedActions')) a)
                                                              AS recommended_actions
    FROM UNNEST(e.reports) r
    WHERE JSON_VALUE(r, '$.detectionState') = 'DETECTED'
  )                                                           AS detected,
  ARRAY_TO_STRING(
    ARRAY(SELECT JSON_VALUE(r, '$.analyzer') FROM UNNEST(e.reports) r
          WHERE JSON_VALUE(r, '$.detectionState') = 'DETECTED'
          ORDER BY 1), ', ')                                  AS detected_analyzers
FROM events e;
