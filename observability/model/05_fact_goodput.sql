-- fact_goodput: per-job TPU productivity and cost.
--
-- "Goodput" here is deliberately a measured proxy, not a claim about the
-- training loop: the fraction of a job's wall-clock during which its TPU chips
-- were actually doing tensorcore work. It is computed from
-- kubernetes.io/container/accelerator/tensorcore_utilization sampled at 5-minute
-- means, so a bucket counts as productive when the chips averaged above
-- IDLE_THRESHOLD over those 5 minutes.
--
-- What this does NOT measure: whether the steps were useful (a job can burn
-- 100% tensorcore on a diverging run), or time lost before the first chip is
-- allocated. Queue/scheduling time is visible separately as the gap between
-- dim_mlrun.workload_create_time and the first utilisation sample.
--
-- Chip-hours come from COUNT(DISTINCT accelerator_id) per pod, which is the
-- honest denominator: it counts chips the job actually held, including ones it
-- held while idle.

CREATE OR REPLACE VIEW `tpu-for-training.mlobs_core.fact_goodput` AS
WITH util AS (
  SELECT
    `tpu-for-training.mlobs_core.job_key_from_pod`(
      JSON_VALUE(resource_labels.pod_name))            AS job_key,
    JSON_VALUE(resource_labels.pod_name)               AS pod_name,
    JSON_VALUE(metric_labels.accelerator_id)           AS chip_id,
    JSON_VALUE(metric_labels.model)                    AS tpu_model,
    point_time,
    value                                              AS tensorcore_pct
  FROM `tpu-for-training.mlobs_raw.metric_samples`
  WHERE metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
),
-- collapse chips to one row per (job, 5-min bucket): a bucket is productive if
-- the job's chips averaged above the idle threshold across the whole slice
buckets AS (
  SELECT
    job_key,
    point_time,
    AVG(tensorcore_pct)                    AS mean_tensorcore_pct,
    COUNT(DISTINCT CONCAT(pod_name, '/', chip_id)) AS chips,
    ANY_VALUE(tpu_model)                   AS tpu_model
  FROM util
  GROUP BY job_key, point_time
),
rolled AS (
  SELECT
    job_key,
    ANY_VALUE(tpu_model)                                    AS tpu_model,
    MIN(point_time)                                         AS first_sample,
    MAX(point_time)                                         AS last_sample,
    COUNT(*)                                                AS buckets_total,
    COUNTIF(mean_tensorcore_pct > 10.0)                     AS buckets_productive,
    -- each bucket is a 5-minute slice of `chips` chips
    SUM(chips) * 5 / 60.0                                   AS chip_hours,
    SUM(IF(mean_tensorcore_pct > 10.0, chips, 0)) * 5 / 60.0 AS chip_hours_productive,
    AVG(mean_tensorcore_pct)                                AS avg_tensorcore_pct,
    MAX(chips)                                              AS peak_chips
  FROM buckets
  WHERE job_key IS NOT NULL
  GROUP BY job_key
)
SELECT
  r.*,
  SAFE_DIVIDE(r.buckets_productive, r.buckets_total)          AS goodput_ratio,
  r.chip_hours - r.chip_hours_productive                      AS chip_hours_wasted,
  m.run_phase,
  m.namespace_name,
  m.cluster_name,
  m.workload_create_time,
  m.end_time                                                  AS run_end_time,
  -- time between the workload being admitted and its first busy chip
  TIMESTAMP_DIFF(r.first_sample, m.workload_create_time, SECOND) AS startup_lag_s,
  p.usd_per_chip_hour,
  ROUND(r.chip_hours * p.usd_per_chip_hour, 2)                AS est_usd,
  ROUND((r.chip_hours - r.chip_hours_productive)
        * p.usd_per_chip_hour, 2)                             AS est_usd_wasted
FROM rolled r
-- a workload name can be reused across runs (retries, same-name reruns); take
-- the run whose window actually covers the utilisation samples
LEFT JOIN (
  SELECT * EXCEPT(rn) FROM (
    SELECT m.*, ROW_NUMBER() OVER (
             PARTITION BY gke_workload_name ORDER BY create_time DESC) AS rn
    FROM `tpu-for-training.mlobs_core.dim_mlrun` m)
  WHERE rn = 1
) m ON m.gke_workload_name = r.job_key
-- on-demand list price; spot/committed rates live in the same table but must be
-- selected explicitly, otherwise every job fans out to one row per rate
LEFT JOIN `tpu-for-training.mlobs_core.dim_tpu_price` p
  ON p.tpu_model = r.tpu_model
 AND p.usage_type = 'OnDemand'
 AND p.region = 'us-central1';
