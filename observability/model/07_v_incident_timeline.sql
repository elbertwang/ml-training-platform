-- v_incident_timeline: the single view an on-call engineer opens.
--
-- Same shape as v_job_timeline but with two extra signal sources that do not
-- come from logs at all:
--
--   log_rate   from logging.googleapis.com/log_entry_count. A log storm is a
--              first-class incident signal here -- it means a component is in a
--              retry loop -- and reading it from the metric costs nothing,
--              whereas detecting it in the logs would mean scanning the WARNING
--              tier (75% of all volume in this project).
--   tpu_idle   from tensorcore_utilization. Chips allocated but not working is
--              the symptom the whole platform exists to explain.
--
-- Thresholds are deliberately blunt: 10k log lines per 5-minute bucket per
-- container, and tensorcore under 5%. They are there to make the timeline
-- readable, not to be a tuned detector.

CREATE OR REPLACE VIEW `tpu-for-training.mlobs_core.v_incident_timeline` AS

SELECT event_time, job_key, source, severity, event_type, summary,
       pod_name, node_name, occurrences
FROM `tpu-for-training.mlobs_core.fact_event`

UNION ALL

SELECT
  point_time                                        AS event_time,
  `tpu-for-training.mlobs_core.job_key_from_pod`(
    JSON_VALUE(resource_labels.pod_name))           AS job_key,
  'log_rate'                                        AS source,
  'WARNING'                                         AS severity,
  JSON_VALUE(resource_labels.container_name)        AS event_type,
  FORMAT('log storm: %d lines in 5min from container %s',
         CAST(value AS INT64),
         JSON_VALUE(resource_labels.container_name)) AS summary,
  JSON_VALUE(resource_labels.pod_name)              AS pod_name,
  CAST(NULL AS STRING)                              AS node_name,
  CAST(value AS INT64)                              AS occurrences
FROM `tpu-for-training.mlobs_raw.metric_samples`
WHERE metric_type = 'logging.googleapis.com/log_entry_count'
  AND value > 10000

UNION ALL

SELECT
  point_time                                        AS event_time,
  `tpu-for-training.mlobs_core.job_key_from_pod`(
    JSON_VALUE(resource_labels.pod_name))           AS job_key,
  'tpu_idle'                                        AS source,
  'WARNING'                                         AS severity,
  'tensorcore_idle'                                 AS event_type,
  FORMAT('tensorcore at %.1f%% on chip %s',
         value, JSON_VALUE(metric_labels.accelerator_id)) AS summary,
  JSON_VALUE(resource_labels.pod_name)              AS pod_name,
  CAST(NULL AS STRING)                              AS node_name,
  1                                                 AS occurrences
FROM `tpu-for-training.mlobs_raw.metric_samples`
WHERE metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
  AND value < 5.0;
