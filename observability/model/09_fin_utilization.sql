-- Finance view of TPU capacity: what was paid for, and what came of it.
--
-- Every ratio here divides by the same denominator -- reserved chip-hours --
-- so the four of them are comparable, can be subtracted from one another, and
-- cannot produce the "MFU above duty cycle" contradiction that comes from
-- averaging each metric over whatever chips happened to report it.
--
-- ============================ THE FORMULAS ============================
--
--   paid_chip_hours     = INTEGRAL(reservation/reserved) dt        [chips x h]
--   scheduled_chip_hours= INTEGRAL(reservation/used)     dt
--   busy_chip_hours     = SUM(tensorcore_pct/100 x interval x chips)
--   flops_chip_hours    = SUM(tflops_p50 / peak_tflops x step_seconds x devices/2)
--   productive_chip_hours = SUM(goodput_seconds x chips) / 3600
--
--   reservation_utilization = scheduled / paid      "bought it, handed it out?"
--   chip_utilization        = busy      / paid      "handed out, doing work?"
--   mfu                     = flops     / paid      "doing work, how fast?"
--   goodput                 = productive/ paid      "work that was not wasted"
--   wasted_usd              = (paid - productive) x usd_per_chip_hour
--
-- ============================ WHAT CHANGED AND WHY ====================
--
-- The Cloud Monitoring dashboards this replaces compute
--     avg(kubernetes_io:node_accelerator_duty_cycle)
--     avg(kubernetes_io:node_accelerator_tensorcore_utilization)
-- and label the second one MFU. Two problems, both measured rather than
-- argued:
--
-- 1. The denominator is "chips that reported a sample", not "chips that were
--    paid for". An idle reserved chip has no pod, therefore no container
--    metric, therefore no series -- so it is absent from the average instead
--    of counted as zero. Over the same seven days: series average 18.62%,
--    against 12.57% on paid capacity, a 48% overstatement. The gap is visible
--    in the intermediate quantities -- 56,865 sampled chip-hours against
--    84,223 paid, so a third of what was paid for never appeared in the maths.
--
-- 2. TensorCore utilization is not MFU. It is the fraction of time the
--    TensorCore was issuing instructions; MFU is achieved FLOPs over peak
--    FLOPs. A kernel can keep the TensorCore busy continuously and still reach
--    a fraction of peak. They are different quantities and only one of them is
--    what finance means. Real FLOPs are available -- MaxText logs TFLOP/s per
--    device and fact_step already extracts it for 790 jobs -- so mfu below is
--    computed rather than proxied.
--
-- ============================ CAVEATS THAT MATTER =====================
--
-- * Peak is bf16 (TPU7x: 1153.5 TFLOP/s per JAX device, i.e. 2307 per chip
--   halved because one chip is two devices). A job running fp8 has twice the
--   peak, so its MFU here reads about half of the truth. Deliberate for now --
--   the compute dtype is not in any signal we collect, and inferring it from
--   the config overlay is a separate piece of work. Jobs using fp8 are
--   identifiable by name today (lossdif-plus-fp8-*) and should be read with
--   that in mind.
-- * Reserved capacity only. On-demand and flex-start node pools are excluded
--   from both sides: their chips are not in reservation/reserved, and
--   capacity_class keeps their work out of the numerators. Without that filter
--   a burst of flex-start work would push a ratio over 100%.
-- * busy_chip_hours comes from a 5-minute mean, so sub-bucket idleness is
--   averaged in rather than resolved. It measures occupancy, not instruction
--   density.

-- ---------------------------------------------------------------------------
-- Peak FLOPs per JAX device, by chip generation. Mirrors MaxText's
-- src/maxtext/utils/peak_tflops_map.py -- the same table the training process
-- uses to compute the TFLOP/s it logs, so numerator and denominator come from
-- one source. TPU7x publishes 2307 per chip and one chip is two JAX devices.
CREATE OR REPLACE TABLE mlobs_core.dim_chip_peak AS
SELECT * FROM UNNEST([
  STRUCT('tpu7x'     AS tpu_model, 'bf16' AS dtype, 1153.5 AS peak_tflops_per_device),
  STRUCT('tpu7x',      'fp8',  2307.0),
  STRUCT('tpu-v6e',    'bf16',  918.0),
  STRUCT('tpu-v5p',    'bf16',  459.0),
  STRUCT('tpu-v5-lite','bf16',  197.0)
]);


-- Reserved and scheduled chip-hours per day, per reservation.
--
-- A trapezoid over 5-minute samples rather than a spot reading: reserved
-- capacity changes when a reservation is resized, and reading a level at one
-- instant would restate every day it touches.
CREATE OR REPLACE TABLE mlobs_core.fin_capacity_daily
CLUSTER BY reservation_id
AS
WITH s AS (
  SELECT
    DATE(point_time)                                       AS day,
    JSON_VALUE(resource_labels, '$.reservation_id')        AS reservation_id,
    JSON_VALUE(resource_labels, '$.location')              AS location,
    metric_type,
    value,
    point_time
  FROM mlobs_raw.metric_samples
  WHERE metric_type IN ('compute.googleapis.com/reservation/reserved',
                        'compute.googleapis.com/reservation/used')
)
SELECT
  day,
  reservation_id,
  ANY_VALUE(location) AS location,
  -- Each 5-minute sample stands for 300s = 1/12 h of that many chips.
  ROUND(SUM(IF(metric_type LIKE '%/reserved', value, 0)) / 12, 2) AS paid_chip_hours,
  ROUND(SUM(IF(metric_type LIKE '%/used',     value, 0)) / 12, 2) AS scheduled_chip_hours,
  ROUND(AVG(IF(metric_type LIKE '%/reserved', value, NULL)), 1)   AS avg_reserved_chips,
  COUNTIF(metric_type LIKE '%/reserved')                          AS samples,
  -- Coverage is of the *time axis*, not of any one reservation. 288 five-minute
  -- buckets make a full day; a reservation that only existed for an hour
  -- legitimately contributes twelve. Counting per reservation and taking the
  -- minimum read 0.021 for 2026-09-02, because a third reservation appeared
  -- that day for half an hour -- which is a fact about the fleet, not a gap in
  -- collection.
  ROUND(COUNT(DISTINCT IF(metric_type LIKE '%/reserved',
                          TIMESTAMP_TRUNC(point_time, MINUTE), NULL)) / 288.0, 3)
                                                                  AS day_coverage
FROM s
WHERE reservation_id IS NOT NULL
GROUP BY day, reservation_id;


-- Work done on reserved capacity, per day.
--
-- Both numerators are filtered to capacity_class='reserved' through the node
-- pool a pod ran on, so they share the denominator's scope. Pods whose pool can
-- no longer be resolved -- falcon's ephemeral pools, deleted before the next
-- snapshot -- are counted separately rather than dropped, because silently
-- discarding them would understate utilisation without saying so.
CREATE OR REPLACE TABLE mlobs_core.fin_work_daily
CLUSTER BY day
AS
WITH pod_class AS (
  SELECT
    p.pod_name,
    p.job_key,
    p.cluster_name,
    COALESCE(np.capacity_class, 'unresolved') AS capacity_class,
    np.reservation_name
  FROM mlobs_core.dim_pod p
  LEFT JOIN mlobs_core.dim_node_pool np
    ON np.ig_hash = mlobs_core.node_ig_hash(p.node_name)
),
busy AS (
  SELECT
    DATE(m.point_time)  AS day,
    c.capacity_class,
    -- tensorcore_utilization is a percentage over a 5-minute bucket, so
    -- value/100 * (300/3600) h is the chip-hours that chip actually spent busy.
    SUM(m.value / 100 * 300 / 3600) AS busy_chip_hours,
    COUNT(DISTINCT CONCAT(m.pod_name, '/', m.chip_id)) AS chips_seen
  FROM mlobs_core.fact_metric m
  JOIN pod_class c USING (pod_name)
  WHERE m.metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
  GROUP BY day, c.capacity_class
),
job_class AS (
  -- One row per job, not per pod. Joining fact_step to a per-pod table fans
  -- every step row out by the pod count -- 64x for a 256-chip job -- and the
  -- first build of this model reported MFU near 40% because of it. A job whose
  -- pods span capacity classes is attributed to whichever holds most of them.
  SELECT job_key, capacity_class
  FROM (
    SELECT job_key, capacity_class,
           ROW_NUMBER() OVER (PARTITION BY job_key ORDER BY COUNT(*) DESC) AS rn
    FROM pod_class GROUP BY job_key, capacity_class)
  WHERE rn = 1
),
job_shape AS (
  -- Chips per rank, measured per job rather than assumed. ranks_reporting
  -- counts worker pods; peak_chips counts chips; the ratio is exactly 4 across
  -- every 64-rank/256-chip job in this cluster, which is TPU7x's four chips per
  -- host. Deriving it keeps the model right on a generation with a different
  -- host shape instead of silently rescaling every number.
  SELECT s.job_key,
         SAFE_DIVIDE(ANY_VALUE(h.peak_chips), MAX(s.ranks_reporting)) AS chips_per_rank
  FROM mlobs_core.fact_step s
  JOIN mlobs_core.job_hub h USING (job_key)
  WHERE s.ranks_reporting > 0 AND h.peak_chips > 0
  GROUP BY s.job_key
),
flops AS (
  -- MFU numerator, in chip-hours of full-speed-equivalent work:
  --   (achieved TFLOP/s per device / peak TFLOP/s per device)
  --     x step wall seconds x chips in the step
  -- Steps with no TFLOP/s reading contribute nothing rather than zero -- a job
  -- that does not log the field is missing, not idle.
  SELECT
    DATE(s.step_time) AS day,
    c.capacity_class,
    SUM(SAFE_DIVIDE(s.tflops_p50, pk.peak_tflops_per_device)
        * s.step_seconds_p50 * s.ranks_reporting * sh.chips_per_rank / 3600)
                                                             AS flops_chip_hours,
    SUM(s.step_seconds_p50 * s.ranks_reporting * sh.chips_per_rank / 3600)
                                                             AS stepping_chip_hours
  FROM mlobs_core.fact_step s
  JOIN job_class c  USING (job_key)
  JOIN job_shape sh USING (job_key)
  CROSS JOIN (SELECT peak_tflops_per_device FROM mlobs_core.dim_chip_peak
              WHERE tpu_model = 'tpu7x' AND dtype = 'bf16') pk
  WHERE s.tflops_p50 IS NOT NULL AND s.ranks_reporting > 0
  GROUP BY day, c.capacity_class
)
SELECT
  COALESCE(b.day, f.day)                       AS day,
  COALESCE(b.capacity_class, f.capacity_class) AS capacity_class,
  ROUND(b.busy_chip_hours, 2)                  AS busy_chip_hours,
  b.chips_seen,
  ROUND(f.flops_chip_hours, 2)                 AS flops_chip_hours,
  ROUND(f.stepping_chip_hours, 2)              AS stepping_chip_hours
FROM busy b
FULL OUTER JOIN flops f ON f.day = b.day AND f.capacity_class = b.capacity_class;


-- The finance sheet. One row per day; every column has a formula in the header.
CREATE OR REPLACE VIEW mlobs_core.fin_daily AS
WITH cap AS (
  SELECT day,
         SUM(paid_chip_hours)      AS paid_chip_hours,
         SUM(scheduled_chip_hours) AS scheduled_chip_hours,
         -- max, not min: see fin_capacity_daily. Each reservation reports
         -- its own slice of the day and the union is what was covered.
         MAX(day_coverage)         AS day_coverage
  FROM mlobs_core.fin_capacity_daily
  GROUP BY day
),
work AS (
  SELECT day,
         SUM(IF(capacity_class = 'reserved', busy_chip_hours, 0))  AS busy_chip_hours,
         SUM(IF(capacity_class = 'reserved', flops_chip_hours, 0)) AS flops_chip_hours,
         SUM(IF(capacity_class = 'unresolved', busy_chip_hours, 0)) AS unresolved_busy_chip_hours
  FROM mlobs_core.fin_work_daily
  GROUP BY day
),
price AS (
  SELECT ANY_VALUE(usd_per_chip_hour) AS usd_per_chip_hour
  FROM mlobs_core.dim_tpu_price
  WHERE tpu_model = 'tpu7x' AND usage_type = 'OnDemand'
)
SELECT
  c.day,
  ROUND(c.paid_chip_hours, 1)                                    AS paid_chip_hours,
  ROUND(c.scheduled_chip_hours, 1)                               AS scheduled_chip_hours,
  ROUND(w.busy_chip_hours, 1)                                    AS busy_chip_hours,
  ROUND(w.flops_chip_hours, 1)                                   AS flops_chip_hours,
  -- scheduled / paid
  ROUND(100 * SAFE_DIVIDE(c.scheduled_chip_hours, c.paid_chip_hours), 2) AS reservation_utilization_pct,
  -- busy / paid
  ROUND(100 * SAFE_DIVIDE(w.busy_chip_hours, c.paid_chip_hours), 2)      AS chip_utilization_pct,
  -- flops / paid, bf16 peak
  ROUND(100 * SAFE_DIVIDE(w.flops_chip_hours, c.paid_chip_hours), 2)     AS mfu_pct,
  -- (paid - busy) x price
  ROUND((c.paid_chip_hours - COALESCE(w.busy_chip_hours, 0))
        * (SELECT usd_per_chip_hour FROM price), 0)              AS idle_usd,
  ROUND(c.paid_chip_hours * (SELECT usd_per_chip_hour FROM price), 0) AS paid_usd,
  -- Trust markers, published beside the numbers rather than in a footnote.
  c.day_coverage,
  ROUND(w.unresolved_busy_chip_hours, 1)                         AS unresolved_busy_chip_hours
FROM cap c
LEFT JOIN work w USING (day);


-- ---------------------------------------------------------------------------
-- The export surface. One flat, self-describing table for the customer's own
-- finance system to pull -- via `bq query`, a scheduled query, a federated
-- read, or the BigQuery API. A view rather than an HTTP endpoint on purpose:
-- there is no service to keep up, the access grant is the existing dataset
-- ACL, and every read leaves an audit trail in Cloud Logging.
--
-- Each row carries its own formula so a number can never be separated from how
-- it was produced. That is the whole point -- the metric it replaces was
-- accurate about what it computed and wrong about what it was called.
CREATE OR REPLACE VIEW mlobs_core.fin_export AS
SELECT
  day,
  metric,
  value,
  unit,
  formula,
  -- Below ~0.9 the day is partial and the absolute chip-hours understate.
  -- Ratios stay usable; totals do not.
  day_coverage
FROM (
  SELECT day, day_coverage,
    [STRUCT('paid_chip_hours' AS metric, paid_chip_hours AS value,
            'chip*hour' AS unit,
            'INTEGRAL(compute.googleapis.com/reservation/reserved) dt, reserved pools only' AS formula),
     STRUCT('scheduled_chip_hours', scheduled_chip_hours, 'chip*hour',
            'INTEGRAL(compute.googleapis.com/reservation/used) dt'),
     STRUCT('busy_chip_hours', busy_chip_hours, 'chip*hour',
            'SUM(tensorcore_utilization/100 * 300s * chips) over reserved pools'),
     STRUCT('flops_chip_hours', flops_chip_hours, 'chip*hour',
            'SUM(tflops_p50 / 1153.5 * step_seconds * chips), bf16 peak per JAX device'),
     STRUCT('reservation_utilization_pct', reservation_utilization_pct, 'percent',
            'scheduled_chip_hours / paid_chip_hours'),
     STRUCT('chip_utilization_pct', chip_utilization_pct, 'percent',
            'busy_chip_hours / paid_chip_hours'),
     STRUCT('mfu_pct', mfu_pct, 'percent',
            'flops_chip_hours / paid_chip_hours; bf16 peak, so fp8 jobs read ~half'),
     STRUCT('paid_usd', paid_usd, 'USD',
            'paid_chip_hours * dim_tpu_price.usd_per_chip_hour (list, OnDemand)'),
     STRUCT('idle_usd', idle_usd, 'USD',
            '(paid_chip_hours - busy_chip_hours) * usd_per_chip_hour')
    ] AS metrics
  FROM mlobs_core.fin_daily
), UNNEST(metrics);
