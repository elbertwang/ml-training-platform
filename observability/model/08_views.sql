-- Serving layer: the views and table functions the per-job page reads.

-- URL-encoding helper. BigQuery has no native percent-encode, and the deep
-- links below embed Cloud Logging queries that contain quotes, spaces and
-- newlines.
CREATE OR REPLACE FUNCTION mlobs_core.url_encode(s STRING)
RETURNS STRING
LANGUAGE js
AS r"""
  if (s === null) return null;
  return encodeURIComponent(s);
""";


-- v_incident_timeline: everything on one clock.
--
-- Now a thin projection of fact_event. The metric-derived sources (log_rate,
-- tpu_idle) used to be UNIONed in here from metric_samples; that made every
-- per-job query scan the whole metric table, because job_key on those rows only
-- exists after a join to dim_pod and so cannot be pushed down. They are
-- materialised into fact_event instead -- see 04_fact_event.sql.
CREATE OR REPLACE VIEW mlobs_core.v_incident_timeline AS
SELECT event_time, job_key, attempt_uid, source, severity, event_type, summary,
       pod_name, node_name, occurrences
FROM mlobs_core.fact_event;


-- v_job_error_burst: pods emitting an abnormal rate of identical errors.
-- A log storm is both an incident symptom and a direct cost event.
CREATE OR REPLACE VIEW mlobs_core.v_job_error_burst AS
SELECT
  TIMESTAMP_TRUNC(event_time, HOUR) AS hour,
  job_key,
  event_type                        AS container_name,
  summary                           AS message_signature,
  COUNT(DISTINCT pod_name)          AS pods,
  SUM(occurrences)                  AS lines,
  ROUND(SUM(occurrences) / 60.0, 1) AS lines_per_minute,
  -- Cloud Logging bills the whole LogEntry; measured mean in tpu-for-training
  -- is ~1.4 KB/entry (1,631 GiB/day over ~1.24B entries) at $0.50/GiB.
  ROUND(SUM(occurrences) * 1400 / POW(2, 30) * 0.50, 2) AS est_logging_usd
FROM mlobs_core.fact_event
WHERE source = 'app_error'
GROUP BY 1, 2, 3, 4
HAVING lines > 10000;


-- job_hub: one row per job, with the deep links that make it a landing page.
--
-- Materialised, not a view. It aggregates fact_goodput and fact_event across
-- every job, and an aggregate cannot be pruned by a downstream job_key filter:
-- as a view, opening one job's page scanned 46.9 MB where the timeline scanned
-- 0.6 MB. One row per job is small enough to rebuild each cycle.
--
-- Links are computed here rather than in the reporting tool so that every
-- consumer (Looker Studio, a notebook, a chat bot) gets the same ones. The
-- Logs Explorer link is what satisfies "show me all the logs": full fidelity,
-- free, and a better log UI than anything we would build -- but it only reaches
-- back as far as the log bucket's retention, so old jobs will land on an empty
-- Logs Explorer. `logs_available` says whether to expect anything.
CREATE OR REPLACE TABLE mlobs_core.job_hub
CLUSTER BY job_key
AS
WITH cfg AS (SELECT project_id, log_retention_days FROM mlobs_core.dim_config),
agg AS (
  SELECT
    g.job_key,
    SUM(g.wallclock_chip_hours)  AS chip_hours,
    MAX(g.peak_chips)            AS peak_chips,
    ANY_VALUE(g.tpu_model)       AS tpu_model,
    SAFE_DIVIDE(SUM(g.wallclock_chip_hours * g.goodput_ratio),
                SUM(g.wallclock_chip_hours)) AS goodput_ratio,
    SUM(g.est_usd)               AS est_usd,
    SUM(g.est_usd_wasted)        AS est_usd_wasted,
    SUM(g.est_usd_observed)      AS est_usd_observed,
    SUM(g.est_usd_wasted_observed) AS est_usd_wasted_observed,
    MIN(g.sample_coverage)       AS min_sample_coverage
  FROM mlobs_core.fact_goodput g
  GROUP BY g.job_key
),
ev AS (
  SELECT
    job_key,
    COUNTIF(source = 'mldiag')     AS mldiag_events,
    COUNTIF(source = 'app_error')  AS error_signatures,
    SUM(IF(source = 'app_error', occurrences, 0)) AS error_lines,
    MAX(IF(source = 'log_rate', occurrences, 0))  AS peak_log_rate_5min
  FROM mlobs_core.v_incident_timeline
  GROUP BY job_key
)
SELECT
  j.job_key,
  j.job_family,
  j.namespace_name,
  j.cluster_name,
  j.location,
  j.owner,
  j.exp_id,
  j.attempts,
  j.peak_nodes,
  j.first_seen,
  j.last_seen,
  j.run_phase,
  j.mlrun_id,
  a.peak_chips,
  a.tpu_model,
  ROUND(a.chip_hours, 2)          AS chip_hours,
  ROUND(a.goodput_ratio * 100, 1) AS goodput_pct,
  a.est_usd,
  a.est_usd_wasted,
  a.est_usd_observed,
  a.est_usd_wasted_observed,
  -- below ~0.5 the wallclock cost columns are extrapolation, not measurement
  a.min_sample_coverage,
  ev.mldiag_events,
  ev.error_signatures,
  ev.error_lines,
  ev.peak_log_rate_5min,
  j.last_seen >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(),
                               INTERVAL cfg.log_retention_days DAY) AS logs_available,
  -- ---- deep links ----
  FORMAT('https://console.cloud.google.com/logs/query;query=%s;timeRange=%s%%2F%s?project=%s',
         mlobs_core.url_encode(FORMAT(
           'resource.labels.cluster_name="%s"\nresource.labels.namespace_name="%s"\nlabels."logging.gke.io/top_level_controller_name"=~"^%s"',
           j.cluster_name, j.namespace_name, j.job_key)),
         FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', TIMESTAMP_SUB(j.first_seen, INTERVAL 10 MINUTE)),
         FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', TIMESTAMP_ADD(j.last_seen, INTERVAL 10 MINUTE)),
         cfg.project_id) AS logs_explorer_url,
  FORMAT('https://console.cloud.google.com/logs/analytics?project=%s', cfg.project_id)
                                  AS log_analytics_url,
  FORMAT('https://console.cloud.google.com/monitoring/metrics-explorer?project=%s', cfg.project_id)
                                  AS monitoring_url,
  -- Cluster Director / ML Diagnostics. Path shape is not documented; the
  -- project-scoped landing page is used until the deep path is verified
  -- against a live console session.
  IF(j.mlrun_id IS NULL, NULL,
     FORMAT('https://console.cloud.google.com/cluster-director?project=%s', cfg.project_id))
                                  AS cluster_director_url
FROM mlobs_core.dim_job j
CROSS JOIN cfg
LEFT JOIN agg a USING (job_key)
LEFT JOIN ev  USING (job_key);


-- ---- Table functions for the reporting layer ----
--
-- Looker Studio must call these rather than reading the views directly. A
-- report-level filter is applied AFTER BigQuery returns rows, so connecting
-- straight to a view scans everything on every page load. Passing job_key into
-- a TVF pushes the predicate down to `CLUSTER BY job_key`, which is the
-- difference between a few MB and a full scan per refresh.

CREATE OR REPLACE TABLE FUNCTION mlobs_core.job_overview(p_job_key STRING) AS
SELECT * FROM mlobs_core.job_hub WHERE job_key = p_job_key;

CREATE OR REPLACE TABLE FUNCTION mlobs_core.job_timeline(p_job_key STRING) AS
SELECT * FROM mlobs_core.v_incident_timeline
WHERE job_key = p_job_key
ORDER BY event_time;

CREATE OR REPLACE TABLE FUNCTION mlobs_core.job_metrics(p_job_key STRING) AS
SELECT point_time, metric_type, pod_name, chip_id, container_name, value
FROM mlobs_core.fact_metric
WHERE job_key = p_job_key;

CREATE OR REPLACE TABLE FUNCTION mlobs_core.job_attempts(p_job_key STRING) AS
SELECT * FROM mlobs_core.fact_goodput WHERE job_key = p_job_key
ORDER BY first_seen;

-- The per-step view an ML engineer opens first. Everything here is parsed from
-- the training log line, so it works today without any workload config change.
--
-- `step_regressed` is the restart detector: a step number lower than the
-- highest one already reached means progress was lost and those steps are being
-- redone. Two details matter.
--
-- Partition by job_key, NOT attempt_uid. A restart usually creates a *new*
-- attempt, so partitioning by attempt would make every crash loop look
-- monotonic -- measured: henry-ling3-plus-fp8-test-pdb2 ran steps 0-29 four
-- times over four attempts, and an attempt-scoped window reports zero
-- regressions for it.
--
-- Compare against the running maximum, not the previous row, because a crash
-- loop replays the same range repeatedly and a lagged comparison only flags the
-- single row at each seam.
CREATE OR REPLACE TABLE FUNCTION mlobs_core.job_steps(p_job_key STRING) AS
SELECT
  * EXCEPT (max_step_so_far),
  step < max_step_so_far AS step_regressed
FROM (
  SELECT
    s.*,
    MAX(step) OVER (
      PARTITION BY job_key ORDER BY step_time
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS max_step_so_far
  FROM mlobs_core.fact_step s
  WHERE job_key = p_job_key
)
ORDER BY step_time;
