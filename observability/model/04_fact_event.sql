-- fact_event: one timeline for everything that happened to a job.
--
-- Reads ONLY from the sink (`v_sink_logs`) and the pollers -- never from the
-- `defaultLink` linked dataset. The previous version scanned defaultLink and
-- cost 75.1 GB ($0.43) per rebuild, which at a 15-minute cadence is ~$1,240 a
-- month, three to eight times the entire platform budget. The sink already
-- holds exactly these rows, pre-filtered, at ~1.8M rows/day. defaultLink is now
-- used for two things only: a one-off backfill of the period before the sink
-- existed, and human ad-hoc forensics.
--
-- Repeated app errors are folded into per-minute counted rows keyed by a
-- message signature (digits and hex ids masked). This is not cosmetic: on
-- 2026-08-24 a gcsfuse cache failure produced 4.8M identical lines per pod per
-- hour, and one-row-per-line would let a single incident dominate the table.
--
-- Metric-derived signals (log_rate, tpu_idle) are materialised here too rather
-- than unioned in at query time. They come from metric_samples, which is
-- clustered by metric_type and whose job_key only exists after a join to
-- dim_pod -- so a WHERE job_key = ... predicate cannot be pushed into it, and a
-- view that unioned them scanned everything on every page load. Folding them
-- into this CLUSTER BY job_key table is what makes the per-job page cheap.
--
-- Jobs are resolved through dim_pod, never by parsing pod names.

DECLARE window_start TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY);
DECLARE window_end   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

CREATE TABLE IF NOT EXISTS mlobs_core.fact_event
(
  event_time     TIMESTAMP NOT NULL,
  job_key        STRING,
  attempt_uid    STRING,
  cluster_name   STRING,
  namespace_name STRING,
  source         STRING NOT NULL,
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

DELETE FROM mlobs_core.fact_event
WHERE event_time >= window_start AND event_time < window_end;

INSERT INTO mlobs_core.fact_event

-- 1. ML Diagnostics monitored events (from the poller, not from logs).
SELECT
  e.start_time AS event_time,
  r.job_key,
  CAST(NULL AS STRING) AS attempt_uid,   -- MLDiag reports per workload, not per attempt
  r.cluster_name,
  r.namespace_name,
  'mldiag' AS source,
  IF(e.detected_analyzers = '', 'WARNING', 'ERROR') AS severity,
  e.event_type,
  IF(e.detected_analyzers = '',
     FORMAT('%s (%d analyzers, none detected)', e.event_type, e.analyzer_count),
     FORMAT('%s -> %s', e.event_type, e.detected_analyzers)) AS summary,
  CAST(NULL AS STRING) AS pod_name,
  CAST(NULL AS STRING) AS node_name,
  1 AS occurrences,
  TO_JSON_STRING(e.detected) AS detail
FROM mlobs_core.fact_mlrun_event e
JOIN mlobs_core.dim_mlrun r USING (mlrun_id)
WHERE e.start_time >= window_start AND e.start_time < window_end

UNION ALL

-- 2. Kubernetes events. involvedObject names the pod or node concerned; the
--    job comes from dim_pod when the object is a pod we know about.
SELECT
  l.timestamp AS event_time,
  p.job_key,
  p.attempt_uid,
  JSON_VALUE(l.resource, '$.labels.cluster_name') AS cluster_name,
  COALESCE(JSON_VALUE(l.resource, '$.labels.namespace_name'),
           JSON_VALUE(l.json_payload, '$.involvedObject.namespace')) AS namespace_name,
  'k8s_event' AS source,
  COALESCE(l.severity, 'INFO') AS severity,
  JSON_VALUE(l.json_payload, '$.reason') AS event_type,
  SUBSTR(JSON_VALUE(l.json_payload, '$.message'), 1, 500) AS summary,
  COALESCE(JSON_VALUE(l.resource, '$.labels.pod_name'),
           IF(JSON_VALUE(l.json_payload, '$.involvedObject.kind') = 'Pod',
              JSON_VALUE(l.json_payload, '$.involvedObject.name'), NULL)) AS pod_name,
  COALESCE(JSON_VALUE(l.resource, '$.labels.node_name'),
           IF(JSON_VALUE(l.json_payload, '$.involvedObject.kind') = 'Node',
              JSON_VALUE(l.json_payload, '$.involvedObject.name'), NULL)) AS node_name,
  COALESCE(SAFE_CAST(JSON_VALUE(l.json_payload, '$.count') AS INT64), 1) AS occurrences,
  JSON_VALUE(l.json_payload, '$.involvedObject.kind') AS detail
FROM mlobs_core.v_sink_logs l
LEFT JOIN mlobs_core.dim_pod p
  ON p.pod_name = COALESCE(JSON_VALUE(l.resource, '$.labels.pod_name'),
                           JSON_VALUE(l.json_payload, '$.involvedObject.name'))
WHERE l.timestamp >= window_start AND l.timestamp < window_end
  AND l.log_id = 'events'

UNION ALL

-- 3. Application errors, folded to (minute, pod, message signature).
SELECT
  event_time, job_key, attempt_uid, cluster_name, namespace_name,
  'app_error' AS source, severity, event_type, summary, pod_name,
  node_name, occurrences, CAST(NULL AS STRING) AS detail
FROM (
  SELECT
    TIMESTAMP_TRUNC(l.timestamp, MINUTE)  AS event_time,
    p.job_key,
    p.attempt_uid,
    JSON_VALUE(l.resource, '$.labels.cluster_name')   AS cluster_name,
    JSON_VALUE(l.resource, '$.labels.namespace_name') AS namespace_name,
    l.severity,
    JSON_VALUE(l.resource, '$.labels.container_name')      AS event_type,
    JSON_VALUE(l.resource, '$.labels.pod_name')            AS pod_name,
    ANY_VALUE(p.node_name)                AS node_name,
    SUBSTR(REGEXP_REPLACE(
      REGEXP_REPLACE(
        -- not every structured payload uses `message`; fall back to the whole
        -- object rather than emitting a blank row
        COALESCE(l.text_payload,
                 JSON_VALUE(l.json_payload, '$.message'),
                 JSON_VALUE(l.json_payload, '$.msg'),
                 JSON_VALUE(l.json_payload, '$.error'),
                 TO_JSON_STRING(l.json_payload),
                 ''),
        r'\b[0-9a-f]{8,}\b', '<hex>'),
      r'\d+', '<n>'), 1, 300)             AS summary,
    COUNT(*)                              AS occurrences
  FROM mlobs_core.v_sink_logs l
  LEFT JOIN mlobs_core.dim_pod p ON p.pod_name = JSON_VALUE(l.resource, '$.labels.pod_name')
  WHERE l.timestamp >= window_start AND l.timestamp < window_end
    AND l.severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')
    AND JSON_VALUE(l.resource, '$.labels.pod_name') IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, summary
)

UNION ALL

-- 4. Cluster autoscaler decisions -- why capacity did or did not arrive.
--    Not pod-scoped, so it lands on the timeline without a job_key and is
--    correlated by time and cluster.
SELECT
  l.timestamp AS event_time,
  CAST(NULL AS STRING) AS job_key,
  CAST(NULL AS STRING) AS attempt_uid,
  JSON_VALUE(l.resource, '$.labels.cluster_name') AS cluster_name,
  CAST(NULL AS STRING) AS namespace_name,
  'autoscaler' AS source,
  COALESCE(l.severity, 'INFO') AS severity,
  COALESCE(JSON_VALUE(l.json_payload, '$.decision.decideTime'),
           JSON_VALUE(l.json_payload, '$.resultInfo.results[0].errorMsg.messageId'),
           'autoscaler') AS event_type,
  SUBSTR(TO_JSON_STRING(l.json_payload), 1, 500) AS summary,
  CAST(NULL AS STRING) AS pod_name,
  CAST(NULL AS STRING) AS node_name,
  1 AS occurrences,
  CAST(NULL AS STRING) AS detail
FROM mlobs_core.v_sink_logs l
WHERE l.timestamp >= window_start AND l.timestamp < window_end
  AND l.log_id = 'container_googleapis_com_cluster_autoscaler_visibility'

UNION ALL

-- 5. Log-rate spikes. A storm means a component is in a retry loop, and
--    logging.googleapis.com/log_entry_count detects it for free -- finding the
--    same thing in the logs would mean scanning the WARNING tier, which is 75%
--    of all volume in tpu-for-training.
SELECT
  s.point_time AS event_time,
  p.job_key,
  p.attempt_uid,
  p.cluster_name,
  p.namespace_name,
  'log_rate' AS source,
  'WARNING'  AS severity,
  JSON_VALUE(s.resource_labels, '$.container_name') AS event_type,
  FORMAT('log storm: %d lines in 5min from container %s',
         CAST(s.value AS INT64),
         JSON_VALUE(s.resource_labels, '$.container_name')) AS summary,
  JSON_VALUE(s.resource_labels, '$.pod_name') AS pod_name,
  p.node_name,
  CAST(s.value AS INT64) AS occurrences,
  CAST(NULL AS STRING) AS detail
FROM mlobs_raw.metric_samples s
LEFT JOIN mlobs_core.dim_pod p
  ON p.pod_name = JSON_VALUE(s.resource_labels, '$.pod_name')
WHERE s.point_time >= window_start AND s.point_time < window_end
  AND s.metric_type = 'logging.googleapis.com/log_entry_count'
  AND s.value > 10000

UNION ALL

-- 6. Idle TPU. Chips allocated but not working is the symptom the whole
--    platform exists to explain, so it belongs on the same timeline.
SELECT
  s.point_time AS event_time,
  p.job_key,
  p.attempt_uid,
  p.cluster_name,
  p.namespace_name,
  'tpu_idle' AS source,
  'WARNING'  AS severity,
  'tensorcore_idle' AS event_type,
  FORMAT('tensorcore at %.1f%% on chip %s',
         s.value, JSON_VALUE(s.metric_labels, '$.accelerator_id')) AS summary,
  JSON_VALUE(s.resource_labels, '$.pod_name') AS pod_name,
  p.node_name,
  1 AS occurrences,
  CAST(NULL AS STRING) AS detail
FROM mlobs_raw.metric_samples s
JOIN mlobs_core.dim_pod p
  ON p.pod_name = JSON_VALUE(s.resource_labels, '$.pod_name')
WHERE s.point_time >= window_start AND s.point_time < window_end
  AND s.metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
  AND s.value < 5.0;
