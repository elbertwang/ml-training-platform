-- fact_goodput: per-attempt TPU productivity and cost.
--
-- Grain is the attempt (one Job object), not the job name, because names are
-- reused and summing across reuses is meaningless.
--
-- "Goodput" is an explicitly measured proxy: the share of 5-minute buckets in
-- which the attempt's chips averaged above IDLE_PCT tensorcore utilisation. It
-- does not claim the training was useful -- a diverging run at 100% tensorcore
-- scores perfectly.
--
-- Two chip-hour figures are published, and the difference between them matters:
--
--   observed_chip_hours  sum over samples actually present. Undercounts when
--                        the exporter missed a window or Monitoring dropped
--                        points.
--   wallclock_chip_hours peak chips x the attempt's observed lifetime. Counts
--                        chips the job held while idle, including startup.
--
-- `sample_coverage` is their ratio. An earlier version published only the
-- sample-derived figure, which silently understated cost whenever collection
-- had a gap. Cost is quoted from the wall-clock figure because that is what
-- gets billed, and the coverage column tells you how much to trust it.

-- Constants are inlined rather than DECLAREd: a script variable is not in
-- scope when a stored view is later executed, so a view body cannot reference
-- one. Keep 300 in step with the alignment period in metrics_exporter.py.
--   idle threshold : 10.0 % mean tensorcore over a bucket
--   bucket length  : 300 s

-- fact_metric: Cloud Monitoring samples resolved to a job, clustered so that
-- per-job queries prune.
--
-- metric_samples is clustered by metric_type -- it has to be, the exporter does
-- not know which job a pod belongs to. That means a per-job metrics query
-- scanned the whole table (45.6 MB in the playground, far worse in production).
-- Joining to dim_pod once at build time and clustering the result by job_key
-- fixes it for every consumer, and lets fact_goodput drop a join.
--
-- **Incremental, not CREATE OR REPLACE.** A full rebuild scans all of
-- metric_samples: 81.4 MB for half a day of production data, so ~4.9 GB once
-- 30 days have accumulated, and at a 15-minute cadence that is ~470 GB/day,
-- about $88/month -- growing linearly with retention. Storage for the same data
-- is under $1/month. The cost of keeping metrics in BigQuery is entirely in how
-- you rebuild, which is the same mistake fact_event made against defaultLink.
-- Six hours, matching the poller's incremental window. Measured scan per
-- rebuild: 0.4 MB for 1h, 2-3 MB for 6h, versus 81.4 MB for a full rebuild of
-- half a day's data. Widen it manually after an outage; the DELETE+INSERT is
-- idempotent over whatever range you choose.
--
-- Caveat: a row's job_key is resolved from dim_pod at insert time and is not
-- revisited once it falls out of the window. In practice logs land 2-5 seconds
-- after they are written while metrics lag 3-4 minutes, so a pod is essentially
-- always in dim_pod before its first sample arrives -- but a pod that somehow
-- logged nothing for six hours would keep a NULL job_key on those rows.
DECLARE metric_window_start TIMESTAMP DEFAULT
  TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR);
DECLARE metric_window_end TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

CREATE TABLE IF NOT EXISTS mlobs_core.fact_metric
(
  point_time     TIMESTAMP NOT NULL,
  metric_type    STRING,
  value          FLOAT64,
  job_key        STRING,
  attempt_uid    STRING,
  pod_name       STRING,
  namespace_name STRING,
  cluster_name   STRING,
  chip_id        STRING,
  tpu_model      STRING,
  container_name STRING
)
PARTITION BY DATE(point_time)
CLUSTER BY job_key, metric_type;

-- Same reason as fact_event: overlapping refreshes must not expose the gap
-- between DELETE and INSERT. See model/04_fact_event.sql.
BEGIN TRANSACTION;

DELETE FROM mlobs_core.fact_metric
WHERE point_time >= metric_window_start AND point_time < metric_window_end;

INSERT INTO mlobs_core.fact_metric
SELECT
  s.point_time,
  s.metric_type,
  s.value,
  p.job_key,
  p.attempt_uid,
  p.pod_name,
  p.namespace_name,
  p.cluster_name,
  JSON_VALUE(s.metric_labels, '$.accelerator_id')   AS chip_id,
  JSON_VALUE(s.metric_labels, '$.model')            AS tpu_model,
  JSON_VALUE(s.resource_labels, '$.container_name') AS container_name
FROM mlobs_raw.metric_samples s
JOIN mlobs_core.dim_pod p
  ON p.pod_name = JSON_VALUE(s.resource_labels, '$.pod_name')
WHERE s.point_time >= metric_window_start AND s.point_time < metric_window_end;


-- Materialised for the same reason job_hub is: it aggregates the whole of
-- metric_samples, and an aggregate cannot be pruned by a downstream
-- job_key filter. As a view, job_attempts("x") scanned 46.6 MB; as a
-- CLUSTER BY job_key table it scans what one job needs.
COMMIT TRANSACTION;

CREATE OR REPLACE TABLE mlobs_core.fact_goodput
CLUSTER BY job_key
AS
WITH util AS (
  SELECT
    attempt_uid, job_key, point_time, pod_name, chip_id, tpu_model,
    value AS tensorcore_pct
  FROM mlobs_core.fact_metric
  WHERE metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
    AND attempt_uid IS NOT NULL
),
buckets AS (
  SELECT
    attempt_uid, job_key, point_time,
    AVG(tensorcore_pct)                            AS mean_tensorcore_pct,
    COUNT(DISTINCT CONCAT(pod_name, '/', chip_id)) AS chips,
    ANY_VALUE(tpu_model)                           AS tpu_model
  FROM util
  GROUP BY attempt_uid, job_key, point_time
),
rolled AS (
  SELECT
    attempt_uid,
    job_key,
    ANY_VALUE(tpu_model)                    AS tpu_model,
    MIN(point_time)                         AS first_sample,
    MAX(point_time)                         AS last_sample,
    COUNT(*)                                AS buckets_total,
    COUNTIF(mean_tensorcore_pct > 10.0) AS buckets_productive,
    MAX(chips)                              AS peak_chips,
    AVG(mean_tensorcore_pct)                AS avg_tensorcore_pct,
    SUM(chips) * 300 / 3600.0           AS observed_chip_hours,
    SUM(IF(mean_tensorcore_pct > 10.0, chips, 0)) * 300 / 3600.0
                                            AS observed_chip_hours_productive
  FROM buckets
  GROUP BY attempt_uid, job_key
)
SELECT
  r.attempt_uid,
  r.job_key,
  a.job_family,
  a.namespace_name,
  a.cluster_name,
  a.owner,
  a.exp_id,
  r.tpu_model,
  r.peak_chips,
  a.pods,
  a.nodes,
  r.first_sample,
  r.last_sample,
  a.first_seen,
  a.last_seen,
  ROUND(r.observed_chip_hours, 2)            AS observed_chip_hours,
  ROUND(r.peak_chips * a.observed_duration_s / 3600.0, 2) AS wallclock_chip_hours,
  -- how much of the attempt's lifetime we actually have samples for
  ROUND(SAFE_DIVIDE(r.observed_chip_hours,
                    r.peak_chips * a.observed_duration_s / 3600.0), 3)
                                             AS sample_coverage,
  SAFE_DIVIDE(r.buckets_productive, r.buckets_total) AS goodput_ratio,
  ROUND(r.avg_tensorcore_pct, 2)             AS avg_tensorcore_pct,
  r.buckets_total,
  r.buckets_productive,
  -- time from the first pod log line to the first busy chip
  TIMESTAMP_DIFF(r.first_sample, a.first_seen, SECOND) AS startup_lag_s,
  p.usd_per_chip_hour,
  -- Two cost figures on purpose, because they fail in opposite directions and
  -- `sample_coverage` tells you which to believe:
  --   observed    exact for the time we have samples for; undercounts a gap.
  --   wallclock   what actually gets billed; over-reports if the attempt held
  --               chips we never sampled, e.g. coverage 0.009 on a 7-day pod
  --               with only 12h of exported metrics.
  ROUND(r.observed_chip_hours * p.usd_per_chip_hour, 2)   AS est_usd_observed,
  ROUND(r.peak_chips * a.observed_duration_s / 3600.0 * p.usd_per_chip_hour, 2)
                                                          AS est_usd,
  ROUND(r.observed_chip_hours
        * (1 - COALESCE(SAFE_DIVIDE(r.buckets_productive, r.buckets_total), 0))
        * p.usd_per_chip_hour, 2)                         AS est_usd_wasted_observed,
  ROUND(r.peak_chips * a.observed_duration_s / 3600.0
        * (1 - COALESCE(SAFE_DIVIDE(r.buckets_productive, r.buckets_total), 0))
        * p.usd_per_chip_hour, 2)                         AS est_usd_wasted,
  m.run_phase,
  m.mlrun_id
FROM rolled r
JOIN mlobs_core.dim_job_attempt a USING (attempt_uid)
LEFT JOIN mlobs_core.dim_tpu_price p
  ON p.tpu_model = r.tpu_model AND p.usage_type = 'OnDemand'
LEFT JOIN mlobs_core.dim_job m ON m.job_key = r.job_key;


-- fact_goodput_measured: goodput as the training process itself reports it,
-- rather than inferred from chip utilisation.
--
-- fact_goodput above is a proxy and says so: it scores a diverging run at 100%
-- and cannot say *why* time was lost. This table is the real thing, published by
-- ml-goodput-measurement when a job runs with enable_goodput_recording and
-- monitor_goodput on (primatrix/maxtext#958 made that the default in the
-- submission path). Its decomposition is closed --
--
--     total_elapsed = goodput + SUM(badput by category)
--
-- -- so unexplained time shows up as the OTHER category instead of vanishing.
--
-- Grain is job_key, not attempt_uid. The library keys on workload_id, which is
-- MaxText's run_name, which the submit flow sets to the job name; it has no
-- notion of the Job objects a JobSet creates on retry. Its counters are
-- cumulative across the whole run, which is the more useful grain for "how much
-- of this run was productive" anyway.
--
-- Two ways a job legitimately has no row here, and they are worth telling apart
-- before assuming a bug:
--   * it predates the switches being on, or was submitted from a checkout that
--     predates them -- resolve_config runs on the submitter's machine;
--   * it does not come through scripts/submit at all (falcon/kubemaker), or
--     pins the switches off (the CI loss-validation jobsets).
-- job_hub falls back to the proxy for those, and labels which one it used.
--
-- The counters reset when a run name is reused, so this takes the *latest*
-- point per series rather than the max. A max would silently blend two runs and
-- read high.
CREATE OR REPLACE TABLE mlobs_core.fact_goodput_measured
CLUSTER BY job_key
AS
WITH latest AS (
  -- One row per (workload, metric, category): the most recent cumulative value.
  -- metric_type is listed explicitly rather than matched with LIKE so that
  -- metric_samples' CLUSTER BY metric_type prunes.
  SELECT
    JSON_VALUE(resource_labels, '$.workload_id') AS job_key,
    metric_type,
    COALESCE(JSON_VALUE(metric_labels, '$.badput_source'),
             JSON_VALUE(metric_labels, '$.goodput_source'),
             JSON_VALUE(metric_labels, '$.window_type'))  AS category,
    ARRAY_AGG(value ORDER BY point_time DESC LIMIT 1)[OFFSET(0)] AS value,
    MAX(point_time) AS last_point,
    MIN(point_time) AS first_point
  FROM mlobs_raw.metric_samples
  WHERE metric_type IN (
          'compute.googleapis.com/workload/goodput_time',
          'compute.googleapis.com/workload/badput_time',
          'compute.googleapis.com/workload/total_elapsed_time',
          'compute.googleapis.com/workload/disruptions')
    AND JSON_VALUE(resource_labels, '$.workload_id') IS NOT NULL
  GROUP BY job_key, metric_type, category
),
rolled AS (
  SELECT
    job_key,
    MIN(first_point) AS first_point,
    MAX(last_point)  AS last_point,
    MAX(IF(metric_type LIKE '%/total_elapsed_time', value, NULL)) AS elapsed_s,
    MAX(IF(metric_type LIKE '%/goodput_time',       value, NULL)) AS goodput_s,
    MAX(IF(metric_type LIKE '%/disruptions',        value, NULL)) AS disruptions,
    SUM(IF(metric_type LIKE '%/badput_time',        value, 0))    AS badput_s,
    -- Full fidelity kept alongside the scalars: the categories are the point of
    -- the table, and which ones exist grows as a run progresses.
    ARRAY_AGG(
      IF(metric_type LIKE '%/badput_time' AND value > 0,
         STRUCT(category AS source, ROUND(value, 1) AS seconds), NULL)
      IGNORE NULLS ORDER BY value DESC) AS badput
  FROM latest
  GROUP BY job_key
)
SELECT
  job_key,
  first_point,
  last_point,
  ROUND(elapsed_s, 1)  AS elapsed_s,
  ROUND(goodput_s, 1)  AS goodput_s,
  ROUND(badput_s, 1)   AS badput_s,
  CAST(disruptions AS INT64) AS disruptions,
  ROUND(100 * SAFE_DIVIDE(goodput_s, elapsed_s), 1) AS goodput_pct,
  -- The single biggest reason time was lost, which is the first thing anyone
  -- asks. The full breakdown stays in `badput`.
  badput[SAFE_OFFSET(0)].source  AS top_badput_source,
  badput[SAFE_OFFSET(0)].seconds AS top_badput_s,
  badput,
  -- elapsed - goodput - SUM(badput). The decomposition is supposed to close, so
  -- this is the library's own accounting error, published rather than hidden.
  --
  -- It is not an artefact of how this table samples. All four metrics carry the
  -- same timestamps, and reading every category at one pinned timestamp gives a
  -- residual identical to taking each series' latest point -- measured at -173.5s
  -- on 24,840s elapsed, or -0.7%, for the first job to report. Treat a residual
  -- of a few percent as noise and anything larger as a reason to distrust the
  -- split rather than the total.
  ROUND(elapsed_s - goodput_s - badput_s, 1) AS unaccounted_s
FROM rolled;
