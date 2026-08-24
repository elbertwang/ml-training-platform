-- v_job_timeline: the RCA surface. Everything known about a job, in time order,
-- with a `phase` marker that says whether each row lands inside an ML
-- Diagnostics degradation window.
--
-- The question this answers is the one ML Diagnostics cannot: it reports
-- PERFORMANCE_DEGRADATION with all analyzers NOT_DETECTED for 95.5% of events
-- in this project (4113 events, 184 with any detection). Putting the app errors
-- and Kubernetes events on the same timeline as the degradation window is what
-- turns "something was slow" into "gcsfuse-sidecar started failing at 03:41 on
-- 42 pods and the degradation window opens at 03:44".

CREATE OR REPLACE VIEW `tpu-for-training.mlobs_core.v_job_timeline` AS
WITH degradation_windows AS (
  SELECT
    r.gke_workload_name AS job_key,
    e.start_time,
    e.end_time
  FROM `tpu-for-training.mlobs_core.fact_mlrun_event` e
  JOIN `tpu-for-training.mlobs_core.dim_mlrun` r USING (mlrun_id)
  WHERE e.event_type = 'PERFORMANCE_DEGRADATION'
)
SELECT
  f.event_time,
  f.job_key,
  f.source,
  f.severity,
  f.event_type,
  f.summary,
  f.pod_name,
  f.node_name,
  f.occurrences,
  f.cluster_name,
  f.namespace_name,
  -- does this row fall inside a window the control plane flagged as degraded?
  EXISTS(
    SELECT 1 FROM degradation_windows w
    WHERE w.job_key = f.job_key
      AND f.event_time BETWEEN w.start_time AND w.end_time
  ) AS in_degradation_window
FROM `tpu-for-training.mlobs_core.fact_event` f;


-- v_job_error_burst: pods emitting an abnormal rate of identical errors.
--
-- A log storm is both an incident symptom and a direct cost event: the
-- 2026-08-24 gcsfuse incident wrote ~931M lines in two hours, which at the
-- measured ~1.4 KB billed per entry is roughly 1.2 TiB of Cloud Logging
-- ingestion. Surfacing rate-per-minute makes it alertable.
CREATE OR REPLACE VIEW `tpu-for-training.mlobs_core.v_job_error_burst` AS
SELECT
  TIMESTAMP_TRUNC(event_time, HOUR) AS hour,
  job_key,
  event_type                        AS container_name,
  summary                           AS message_signature,
  COUNT(DISTINCT pod_name)          AS pods,
  SUM(occurrences)                  AS lines,
  ROUND(SUM(occurrences) / 60.0, 1) AS lines_per_minute,
  -- Cloud Logging bills the whole LogEntry; measured mean in this project is
  -- ~1.4 KB/entry (1631 GiB/day over ~1.24B entries) at $0.50/GiB.
  ROUND(SUM(occurrences) * 1400 / POW(2, 30) * 0.50, 2) AS est_logging_usd
FROM `tpu-for-training.mlobs_core.fact_event`
WHERE source = 'app_error'
GROUP BY 1, 2, 3, 4
HAVING lines > 10000;
