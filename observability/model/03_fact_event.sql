-- fact_event: one timeline for everything that happened to a training job.
--
-- This is the table the RCA view is built on. Three sources are normalised into
-- the same shape so a single ORDER BY event_time tells the story:
--
--   mldiag     ML Diagnostics monitored events + which analyzers fired
--   k8s_event  Kubernetes events (OOMKilled, FailedScheduling, preemption, ...)
--   app_error  ERROR+ lines from the workload containers
--
-- Repeated app errors are folded into per-minute counted rows keyed by a message
-- *signature* (digits and hex ids masked out). This is not cosmetic: on
-- 2026-08-24 a gcsfuse-sidecar cache failure produced 4.8M identical lines per
-- pod per hour. Stored one-row-per-line that single incident would dominate the
-- table; stored as signatures it becomes one legible row per minute per pod with
-- occurrences=80000, which is also the shape you want for spotting a log storm.
--
-- Cost note: the defaultLink linked dataset prunes hard on `log_id` and
-- `severity` (~10-12 GB scanned per day of data) but costs ~300 GB/day if you
-- touch the `labels` column unfiltered. Every read below keeps one of those two
-- predicates. Backfill window is a parameter so a rebuild stays bounded.

DECLARE window_start TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY);
DECLARE window_end   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

CREATE TABLE IF NOT EXISTS `tpu-for-training.mlobs_core.fact_event`
(
  event_time     TIMESTAMP  NOT NULL,
  job_key        STRING,
  cluster_name   STRING,
  namespace_name STRING,
  source         STRING     NOT NULL,
  severity       STRING,
  event_type     STRING,
  summary        STRING,
  pod_name       STRING,
  node_name      STRING,
  occurrences    INT64,
  detail         STRING
)
PARTITION BY DATE(event_time)
CLUSTER BY job_key, source;

DELETE FROM `tpu-for-training.mlobs_core.fact_event`
WHERE event_time >= window_start AND event_time < window_end;

INSERT INTO `tpu-for-training.mlobs_core.fact_event`

-- 1. ML Diagnostics monitored events. Small (thousands, all time), already
--    joined to a workload name by the API itself.
SELECT
  e.start_time                                    AS event_time,
  r.gke_workload_name                             AS job_key,
  r.cluster_name,
  r.namespace_name,
  'mldiag'                                        AS source,
  IF(e.detected_analyzers = '', 'WARNING', 'ERROR') AS severity,
  e.event_type,
  IF(e.detected_analyzers = '',
     FORMAT('%s (%d analyzers, none detected)', e.event_type, e.analyzer_count),
     FORMAT('%s -> %s', e.event_type, e.detected_analyzers))
                                                  AS summary,
  CAST(NULL AS STRING)                            AS pod_name,
  CAST(NULL AS STRING)                            AS node_name,
  1                                               AS occurrences,
  TO_JSON_STRING(e.detected)                      AS detail
FROM `tpu-for-training.mlobs_core.fact_mlrun_event` e
JOIN `tpu-for-training.mlobs_core.dim_mlrun` r USING (mlrun_id)
WHERE e.start_time >= window_start AND e.start_time < window_end

UNION ALL

-- 2. Kubernetes events. `log_id` prunes the scan, so reading `labels` here is
--    cheap. involvedObject tells us the pod or node the event is about.
SELECT
  l.timestamp                                     AS event_time,
  `tpu-for-training.mlobs_core.job_key_from_pod`(
    COALESCE(JSON_VALUE(l.resource.labels.pod_name),
             JSON_VALUE(l.json_payload.involvedObject.name)))  AS job_key,
  JSON_VALUE(l.resource.labels.cluster_name)      AS cluster_name,
  COALESCE(JSON_VALUE(l.resource.labels.namespace_name),
           JSON_VALUE(l.json_payload.involvedObject.namespace)) AS namespace_name,
  'k8s_event'                                     AS source,
  COALESCE(l.severity, 'INFO')                    AS severity,
  JSON_VALUE(l.json_payload.reason)               AS event_type,
  SUBSTR(JSON_VALUE(l.json_payload.message), 1, 500) AS summary,
  COALESCE(JSON_VALUE(l.resource.labels.pod_name),
           IF(JSON_VALUE(l.json_payload.involvedObject.kind) = 'Pod',
              JSON_VALUE(l.json_payload.involvedObject.name), NULL)) AS pod_name,
  COALESCE(JSON_VALUE(l.resource.labels.node_name),
           IF(JSON_VALUE(l.json_payload.involvedObject.kind) = 'Node',
              JSON_VALUE(l.json_payload.involvedObject.name), NULL)) AS node_name,
  CAST(COALESCE(SAFE_CAST(JSON_VALUE(l.json_payload.count) AS INT64), 1) AS INT64)
                                                  AS occurrences,
  JSON_VALUE(l.json_payload.involvedObject.kind)  AS detail
FROM `tpu-for-training.defaultLink._AllLogs` l
WHERE l.timestamp >= window_start AND l.timestamp < window_end
  AND l.log_id = 'events'

UNION ALL

-- 3. Application errors, folded to (minute, pod, message signature). The
--    signature masks digits and hex blobs so "process with id 21" and
--    "process with id 86" collapse to one row.
SELECT
  event_time, job_key, cluster_name, namespace_name,
  'app_error' AS source,
  severity, event_type, summary, pod_name,
  CAST(NULL AS STRING) AS node_name,
  occurrences,
  CAST(NULL AS STRING) AS detail
FROM (
  SELECT
    TIMESTAMP_TRUNC(l.timestamp, MINUTE)          AS event_time,
    `tpu-for-training.mlobs_core.job_key_from_pod`(
      JSON_VALUE(l.resource.labels.pod_name))     AS job_key,
    JSON_VALUE(l.resource.labels.cluster_name)    AS cluster_name,
    JSON_VALUE(l.resource.labels.namespace_name)  AS namespace_name,
    l.severity,
    JSON_VALUE(l.resource.labels.container_name)  AS event_type,
    JSON_VALUE(l.resource.labels.pod_name)        AS pod_name,
    SUBSTR(REGEXP_REPLACE(
      REGEXP_REPLACE(
        COALESCE(l.text_payload, JSON_VALUE(l.json_payload.message), ''),
        r'\b[0-9a-f]{8,}\b', '<hex>'),
      r'\d+', '<n>'), 1, 300)                     AS summary,
    COUNT(*)                                      AS occurrences
  FROM `tpu-for-training.defaultLink._AllLogs` l
  WHERE l.timestamp >= window_start AND l.timestamp < window_end
    AND l.severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')
    AND JSON_VALUE(l.resource.labels.pod_name) IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
);
