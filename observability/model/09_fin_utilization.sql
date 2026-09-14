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
--   duty_chip_hours     = SUM(duty_cycle_pct/100 x interval x chips)
--   busy_chip_hours     = SUM(tensorcore_pct/100 x interval x chips)
--   flops_chip_hours    = SUM(tflops_p50 / peak_tflops x step_seconds x chips)
--
--   reservation_utilization = scheduled / paid      "bought it, handed it out?"
--   chip_utilization        = busy      / paid      "handed out, doing work?"
--   mfu                     = flops     / paid      "doing work, how fast?"
--   idle_usd                = (paid - busy) x usd_per_chip_hour
--
-- A goodput row belongs in this set and is not here yet: it needs
-- fact_goodput_measured, which covers a handful of jobs so far because the
-- switches only landed on 2026-08-31. Left out rather than published against a
-- denominator it cannot fill.
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
WITH raw_s AS (
  SELECT
    DATE(point_time)                                       AS day,
    JSON_VALUE(resource_labels, '$.reservation_id')        AS reservation_id,
    JSON_VALUE(resource_labels, '$.location')              AS location,
    metric_type,
    value,
    point_time,
    -- Seconds this sample stands for, measured rather than assumed.
    --
    -- Cloud Monitoring keeps six weeks at full resolution and downsamples
    -- beyond that: a 300s-aligned request returns 288 points a day up to about
    -- day 40 and 144 from day 45. Multiplying every sample by a hard-coded 300s
    -- would therefore halve every chip-hour older than six weeks -- invisibly,
    -- because the number stays plausible. Taking the gap to the previous sample
    -- makes the integral correct at either resolution.
    TIMESTAMP_DIFF(point_time,
      LAG(point_time) OVER (PARTITION BY DATE(point_time),
                                         JSON_VALUE(resource_labels, '$.reservation_id'),
                                         metric_type
                            ORDER BY point_time), SECOND) AS gap_s
  FROM mlobs_raw.metric_samples
  WHERE metric_type IN ('compute.googleapis.com/reservation/reserved',
                        'compute.googleapis.com/reservation/used')
),
s AS (
  SELECT * EXCEPT(gap_s),
    -- The day's first sample has no predecessor inside its partition. Falling
    -- back to a hard 300 was right while everything was 300s and wrong the
    -- moment history arrived at 3600s: it would drop 3,300 seconds from every
    -- day, a 3.8% undercount that lands in paid_chip_hours and in day_coverage.
    -- The partition's smallest observed gap is the sampling period -- gaps only
    -- ever grow, at holes -- so it is the right width for the leading sample at
    -- either resolution, and for a reservation that lived one hour it is still
    -- that reservation's own period rather than a day-length guess.
    COALESCE(gap_s,
             MIN(gap_s) OVER (PARTITION BY day, reservation_id, metric_type),
             300) AS interval_s
  FROM raw_s
)
SELECT
  day,
  reservation_id,
  ANY_VALUE(location) AS location,
  -- value chips held for interval_s seconds.
  ROUND(SUM(IF(metric_type LIKE '%/reserved', value * interval_s, 0)) / 3600, 2) AS paid_chip_hours,
  ROUND(SUM(IF(metric_type LIKE '%/used',     value * interval_s, 0)) / 3600, 2) AS scheduled_chip_hours,
  ROUND(AVG(IF(metric_type LIKE '%/reserved', value, NULL)), 1)   AS avg_reserved_chips,
  COUNTIF(metric_type LIKE '%/reserved')                          AS samples,
  -- Coverage is of the *time axis*, not of any one reservation. 288 five-minute
  -- buckets make a full day; a reservation that only existed for an hour
  -- legitimately contributes twelve. Counting per reservation and taking the
  -- minimum read 0.021 for 2026-09-02, because a third reservation appeared
  -- that day for half an hour -- which is a fact about the fleet, not a gap in
  -- collection.
  -- Coverage as a share of the day actually spanned by samples, which is
  -- resolution-independent for the same reason as the integral above.
  ROUND(LEAST(SUM(IF(metric_type LIKE '%/reserved', interval_s, 0)) / 86400.0, 1.0), 3)
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
-- Rebuilt over a trailing window, not from scratch.
--
-- Every source here is partitioned on time and the table holds one row per day,
-- so replacing it whole means re-reading all history to rewrite rows that
-- cannot change. Measured: the node-metric scan alone is 899 MiB and the
-- container scan behind pod_chip_hours another 662 MiB, every thirty minutes,
-- both growing with retention. Windowed, the same run reads a few percent of
-- that and the cost stops tracking history length.
--
-- Four days, not three. fact_step lands late enough that a three-day window
-- occasionally rewrote a day before its last steps had arrived.
--
-- To rebuild history -- after a backfill lands old samples, which this window
-- will not notice -- widen the interval:
--   sed 's/INTERVAL 4 DAY/INTERVAL 40 DAY/' model/09_fin_utilization.sql | bq query ...
CREATE TABLE IF NOT EXISTS mlobs_core.fin_work_daily
(
  day                 DATE,
  work_coverage       FLOAT64,
  metric_coverage     FLOAT64,
  vm_chip_hours       FLOAT64,
  pod_chip_hours      FLOAT64,
  duty_chip_hours     FLOAT64,
  busy_chip_hours     FLOAT64,
  membw_chip_hours    FLOAT64,
  chips_seen          INT64,
  nodes_seen          INT64,
  flops_chip_hours    FLOAT64,
  stepping_chip_hours FLOAT64
)
CLUSTER BY day;

BEGIN TRANSACTION;

-- The window is whole days on both sides, and it has to be.
--
-- This used to delete `day >= DATE(CURRENT_TIMESTAMP() - 4 days)` -- a whole
-- day -- while every CTE below read `>= CURRENT_TIMESTAMP() - 4 days`, a
-- timestamp. The oldest day in the window was therefore deleted entirely and
-- rebuilt from the hours after the current clock time, losing a little more on
-- each refresh, and frozen at that remnant the moment it slid out of the
-- window. Found on 2026-09-14: fact_chip held 24 hours and 147,460 rows for
-- 2026-09-10, fin_work_daily held 13 hours of them, and global_tpu_utils was
-- NULL for the day because the coverage gate correctly refused a partial one.
-- The gate caught it; nothing else would have.
--
-- Everything below is now anchored to CURRENT_DATE(), matching what
-- fin_occupancy_daily further down already did.
DELETE FROM mlobs_core.fin_work_daily
WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 4 DAY);

INSERT INTO mlobs_core.fin_work_daily
WITH pod_class AS (
  SELECT
    p.pod_name,
    p.job_key,
    p.cluster_name,
    COALESCE(
      np.capacity_class,
      -- falcon creates a node pool per job and deletes it when the job ends,
      -- often inside one 5-minute snapshot interval, so a large share of its
      -- pods can never be resolved to a pool that still exists. Dropping them
      -- is not neutral: they were 39% of all busy chip-hours, and excluding
      -- reserved work from the numerator while its capacity stays in the
      -- denominator understates utilisation by about that much.
      --
      -- They are reserved. Of 90 CreateNodePool audit entries for falcon pools
      -- in one week, 87 requested SPECIFIC_RESERVATION and 3 did not, so this
      -- fallback is right about 97% of the time and its weight is published as
      -- assumed_busy_chip_hours rather than folded in silently.
      --
      -- Checking one entry is how this nearly went the other way: the first
      -- falcon pool sampled happened to be one of the three NO_RESERVATION
      -- ones, which argued for excluding the lot.
      IF(p.job_family = 'falcon', 'reserved_assumed', 'unresolved')
    ) AS capacity_class,
    np.reservation_name
  FROM mlobs_core.dim_pod p
  LEFT JOIN mlobs_core.dim_node_pool np
    ON np.ig_hash = mlobs_core.node_ig_hash(p.node_name)
),
-- Chip-level work, aggregated from fact_chip.
--
-- fact_chip is the atomic grain -- one row per chip per five minutes -- and
-- every quantity below is a sum over it. Reading the metric samples again here
-- with a second weighting rule is what previously made this table and the
-- five-minute table disagree by 13-17%; there is now one derivation and the
-- question cannot arise.
--
-- Each row stands for interval_s seconds, so a chip-hour is summed interval_s
-- over 3600. It is not a row count: the live collector writes 300 and the
-- history loaded from beyond Cloud Monitoring's six-week full-resolution window
-- writes 3600, and counting rows would report one twelfth of the historical
-- work without failing. A slot with no sample contributes no row, which means a
-- collection gap reads as absence rather than being interpolated across. That
-- is the honest reading of "we did not measure it", and the sampling gaps that
-- made it matter were closed at source -- see the interval boundary note in
-- collect/metrics_exporter.py.
busy AS (
  SELECT
    DATE(slot) AS day,
    SUM(interval_s) / 3600.0                               AS vm_chip_hours,
    SUM(IF(pod_name IS NULL, 0, interval_s)) / 3600.0      AS pod_chip_hours,
    SUM(duty_pct       * interval_s) / 100 / 3600.0        AS duty_chip_hours,
    SUM(tensorcore_pct * interval_s) / 100 / 3600.0        AS busy_chip_hours,
    SUM(membw_pct      * interval_s) / 100 / 3600.0        AS membw_chip_hours,
    COUNT(DISTINCT chip_id)                                AS chips_seen,
    COUNT(DISTINCT node_name)                              AS nodes_seen
  FROM mlobs_core.fact_chip
  WHERE slot >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 4 DAY))
  GROUP BY day
),
pool_coverage AS (
  -- What share of that day's pods can be attributed to a capacity class at all.
  --
  -- dim_node_pool is built from snapshots and a snapshot is not retroactive, so
  -- a pool that was deleted before the collector existed can never be resolved.
  -- Re-measured 2026-09-04, after dim_pod was backfilled to 08-05 and grew from
  -- 40k to 109k pods: 100% for 09-02..09-04, 77-90% across 08-28..09-01, 36-46%
  -- across 08-23..08-27, and 9-69% before that. The early days rose -- they read
  -- 3-8% when dim_pod itself started at 08-23 -- because the backfill gave those
  -- pods a node name to resolve against. What remains is a real ceiling, not a
  -- collection gap: 1,378 instance-group hashes appear over the 31 days and
  -- dim_node_pool knows 58 of them, the rest being falcon ephemeral pools that
  -- were deleted long ago.
  --
  -- That gradient is the collector's start date, not a change in the fleet. A
  -- 30-day chart of chip_utilization built without this column shows
  -- utilisation climbing from 1% to 15% and reads as a dramatic improvement;
  -- every point of that climb is an artefact.
  --
  -- The ratio counts pods while the ratios it gates are measured in chip-hours,
  -- which would matter if chipless CPU pods were padding the denominator. They
  -- are not: restricted to pods that carry a tensorcore sample the coverage is
  -- 0.38 vs 0.36 on 08-23, 0.80 vs 0.78 on 08-28, 0.89 vs 0.90 on 08-29. Left
  -- unweighted on that evidence.
  --
  -- Grouped by the day a pod first appeared, while busy_chip_hours is grouped
  -- by the day its samples landed. The two populations differ only for pods
  -- that span midnight, which is 840 of 108,239 -- 0.8%, re-measured on the
  -- backfilled table. Measured rather than waved away, and small enough to
  -- leave as an approximation.
  SELECT
    DATE(p.first_seen) AS day,
    ROUND(COUNTIF(np.ig_hash IS NOT NULL OR p.job_family = 'falcon')
          / COUNT(*), 3) AS work_coverage
  FROM mlobs_core.dim_pod p
  LEFT JOIN mlobs_core.dim_node_pool np
    ON np.ig_hash = mlobs_core.node_ig_hash(p.node_name)
  WHERE p.node_name IS NOT NULL
    AND p.first_seen >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 4 DAY))
  GROUP BY day
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
  WHERE s.step_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 4 DAY))
    AND s.ranks_reporting > 0 AND h.peak_chips > 0
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
        * s.step_seconds_p50 * s.ranks_reporting * COALESCE(sh.chips_per_rank, 4.0) / 3600)
                                                             AS flops_chip_hours,
    SUM(s.step_seconds_p50 * s.ranks_reporting * COALESCE(sh.chips_per_rank, 4.0) / 3600)
                                                             AS stepping_chip_hours
  FROM mlobs_core.fact_step s
  JOIN job_class c  USING (job_key)
  -- LEFT, with a fallback. An inner join dropped 167 of 807 jobs that have
  -- TFLOP/s but no peak_chips in job_hub -- a silent 21% cut of the MFU
  -- numerator. Every job where the ratio *can* be measured comes out at exactly
  -- 4.0, which is TPU7x's four chips per host, so that is the fallback and the
  -- jobs relying on it are counted in fin_daily.
  LEFT JOIN job_shape sh USING (job_key)
  CROSS JOIN (SELECT peak_tflops_per_device FROM mlobs_core.dim_chip_peak
              WHERE tpu_model = 'tpu7x' AND dtype = 'bf16') pk
  WHERE s.step_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 4 DAY))
    AND s.tflops_p50 IS NOT NULL AND s.ranks_reporting > 0
  GROUP BY day, c.capacity_class
),
metric_coverage AS (
  -- How much of the day the accelerator metric itself covers.
  --
  -- The third gate, and the one that was missing. day_coverage watches the
  -- reservation metric (the denominator) and work_coverage watches pod
  -- attribution, but nothing watched the work metric, even though
  -- busy_chip_hours and pod_chip_hours are built entirely from it. A day with a
  -- tensorcore outage and healthy pod attribution passes both existing gates and
  -- publishes an understated numerator, which reads as idle capacity rather than
  -- as a hole in collection -- the same mistake day_coverage exists to prevent,
  -- never applied to this side of the ratio.
  --
  -- Measured 2026-09-04, this was true only by luck: 08-23 holds 4 hours of
  -- tensorcore, 08-24 holds 9, 08-25 none at all and 08-26 holds 23, and every
  -- one of them was already excluded because work_coverage happened to be below
  -- 0.9 on the same days. The two collectors started at about the same time, so
  -- the correlation is an accident of history and not a protection.
  --
  -- Counted in hours rather than 5-minute buckets on purpose. A healthy day only
  -- reaches about 266 of 288 buckets -- series drift and are not perfectly
  -- aligned -- so a 0.9 gate on buckets would sit on the noise floor and suppress
  -- good days. Whole hours separate cleanly: 1.0 for every healthy day above,
  -- 0.17 / 0.375 / 0 / 0.958 for the four damaged ones.
  --
  -- Measured on fact_chip, which is where every numerator above comes from.
  -- It used to be measured on fact_metric's container-scoped series, and while
  -- one resolution and one collector existed the two moved together. They stop
  -- agreeing the moment history arrives: the recovered range has node-scoped
  -- hourly rows in fact_chip and nothing at all in fact_metric, so the gate
  -- read 0 and suppressed all four published ratios for 143 of 184 days --
  -- data that was present, correct, and invisible. A coverage gate has to
  -- measure the table it is guarding.
  SELECT
    DATE(slot) AS day,
    ROUND(COUNT(DISTINCT TIMESTAMP_TRUNC(slot, HOUR)) / 24, 3) AS metric_coverage
  FROM mlobs_core.fact_chip
  WHERE slot >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 4 DAY))
  GROUP BY day
)
-- One row per day. capacity_class is no longer a dimension here: the work
-- metrics are node-scoped and every TPU pool in this project that resolves is
-- reserved, so splitting by class produced one populated class and a residue of
-- unattributable rows. The class breakdown lives in dim_node_pool for anyone
-- who needs it.
SELECT
  COALESCE(b.day, f.day)                       AS day,
  pc.work_coverage,
  mc.metric_coverage,
  -- Chip-hours on a chip whose node was running. The denominator of the two
  -- in-VM ratios, and an independent reading of reservation/used.
  ROUND(b.vm_chip_hours, 2)                    AS vm_chip_hours,
  ROUND(b.pod_chip_hours, 2)                   AS pod_chip_hours,
  ROUND(b.duty_chip_hours, 2)                  AS duty_chip_hours,
  ROUND(b.busy_chip_hours, 2)                  AS busy_chip_hours,
  ROUND(b.membw_chip_hours, 2)                 AS membw_chip_hours,
  b.chips_seen,
  b.nodes_seen,
  ROUND(f.flops_chip_hours, 2)                 AS flops_chip_hours,
  ROUND(f.stepping_chip_hours, 2)              AS stepping_chip_hours
FROM busy b
-- FULL OUTER on the log-derived side: a day can have training steps logged with
-- no accelerator sample, or the reverse, and neither should erase the other.
FULL OUTER JOIN (
  SELECT day, SUM(flops_chip_hours) AS flops_chip_hours,
         SUM(stepping_chip_hours) AS stepping_chip_hours
  FROM flops GROUP BY day
) f USING (day)
LEFT JOIN pool_coverage  pc ON pc.day = COALESCE(b.day, f.day)
LEFT JOIN metric_coverage mc ON mc.day = COALESCE(b.day, f.day);

COMMIT TRANSACTION;


-- Cluster-wide occupancy, with no attribution at all.
--
-- Everything above needs to know which capacity class a pod ran on, and that
-- knowledge starts when the node pool snapshot did -- so the reserved-only
-- ratios cannot reach back before it. This one only sums the accelerator
-- metric, so it goes back as far as Cloud Monitoring keeps the samples, which
-- is where the long trend has to come from.
--
-- It is a different question and the numbers are not interchangeable: this
-- counts every chip in every cluster, on-demand and flex-start included, while
-- chip_utilization_pct counts only capacity that was paid for as reserved. Read
-- together they bracket the fleet; read as one number they are wrong.
-- Incremental, not CREATE OR REPLACE, and the reason is cost rather than taste.
--
-- A full rebuild reads every tensorcore sample ever collected, and mlobs-refresh
-- runs every 30 minutes: 48 full scans a day of a table that only ever grows.
-- Measured 2026-09-04 with 24 days of samples loaded, one rebuild scanned 561 MB
-- -- 27 GB/day, about $5/month. The 90-day backfill in flight multiplies the
-- tensorcore rows by roughly 3.7, taking it to ~$19/month, and it would keep
-- climbing with every day of history for no gain: a past day's occupancy cannot
-- change once its samples have landed.
--
-- metric_samples is DAY-partitioned on point_time and clustered on metric_type,
-- so a windowed read prunes hard -- the same two-day slice scans 15 MB against
-- the full table's 561 MB. Same fix, and the same reasoning, as the dim_pod MERGE
-- in model/01_dim_pod.sql.
--
-- To rebuild history -- after a backfill lands old days, which a two-day window
-- will not notice -- run this file with the interval widened:
--   sed 's/INTERVAL 2 DAY/INTERVAL 95 DAY/; s/INTERVAL 3 DAY/INTERVAL 96 DAY/' \
--     model/09_fin_utilization.sql | bq query ...
--
-- Both intervals, and that is not a detail. Widening only the first one moves
-- the DELETE and the final WHERE out to 95 days while the source read stays at
-- 3, so the statement deletes three months of history and reinserts three days
-- of it.
--
-- Written inline rather than as a DECLARE: BigQuery only accepts variable
-- declarations at the start of a script or block, and this sits mid-file.

CREATE TABLE IF NOT EXISTS mlobs_core.fin_occupancy_daily
(
  day                    DATE,
  busy_chip_hours_all    FLOAT64,
  present_chip_hours_all FLOAT64,
  mean_occupancy_pct     FLOAT64,
  chips_seen             INT64
)
CLUSTER BY day;

BEGIN TRANSACTION;

DELETE FROM mlobs_core.fin_occupancy_daily
WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 2 DAY);

INSERT INTO mlobs_core.fin_occupancy_daily
SELECT
  DATE(point_time) AS day,
  ROUND(SUM(value / 100 * interval_s / 3600), 2) AS busy_chip_hours_all,
  ROUND(SUM(interval_s) / 3600, 2)               AS present_chip_hours_all,
  ROUND(100 * SAFE_DIVIDE(SUM(value / 100 * interval_s),
                          SUM(interval_s)), 2)   AS mean_occupancy_pct,
  COUNT(DISTINCT CONCAT(JSON_VALUE(resource_labels, '$.pod_name'), '/',
                        JSON_VALUE(metric_labels, '$.accelerator_id'))) AS chips_seen
FROM (
  SELECT point_time, value, resource_labels, metric_labels,
         COALESCE(TIMESTAMP_DIFF(point_time,
           LAG(point_time) OVER (
             PARTITION BY JSON_VALUE(resource_labels, '$.pod_name'),
                          JSON_VALUE(metric_labels, '$.accelerator_id')
             ORDER BY point_time), SECOND), 300) AS interval_s
  FROM mlobs_raw.metric_samples
  WHERE metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
    -- One day of lookback beyond the window that gets written. LAG needs the
    -- sample before the first one of the window to measure its interval;
    -- without it every series would restart at the 300s default on the window
    -- boundary and the first day of each run would be slightly understated.
    AND point_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 3 DAY))
)
WHERE DATE(point_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 2 DAY)
GROUP BY day;

COMMIT TRANSACTION;


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
  -- fin_work_daily is already one row per day, so this is a passthrough rather
  -- than an aggregation. It stays as a CTE so the join below reads the same as
  -- the capacity side.
  SELECT
    day,
    vm_chip_hours,
    pod_chip_hours,
    duty_chip_hours,
    busy_chip_hours,
    membw_chip_hours,
    stepping_chip_hours,
    -- NULLIF on the sum, not on the row: zero flops-hours means no job logged
    -- TFLOP/s that day, which is absence of evidence, and publishing it as
    -- "MFU was 0.00%" states the opposite.
    NULLIF(flops_chip_hours, 0) AS flops_chip_hours,
    chips_seen,
    nodes_seen,
    work_coverage,
    metric_coverage
  FROM mlobs_core.fin_work_daily
),
price AS (
  -- The committed rate, not the on-demand one. Every reserved chip in this
  -- fleet is covered by an ACTIVE 36-month commitment -- confirmed through the
  -- reservations' linkedCommitments and the commitments' accelerator counts --
  -- so on-demand is the wrong card to price it from. It was, and the daily
  -- figure was overstated by the whole commitment discount.
  --
  -- Rates come from dim_tpu_price, which this repository creates empty and
  -- never populates; see collect/load_tpu_price.sh.
  SELECT ANY_VALUE(usd_per_chip_hour) AS usd_per_chip_hour
  FROM mlobs_core.dim_tpu_price
  WHERE tpu_model = 'tpu7x' AND usage_type = 'Commit3Yr'
)
SELECT
  c.day,
  ROUND(c.paid_chip_hours, 1)                                    AS paid_chip_hours,
  ROUND(c.scheduled_chip_hours, 1)                               AS scheduled_chip_hours,
  ROUND(w.pod_chip_hours, 1)                                     AS pod_chip_hours,
  ROUND(w.stepping_chip_hours, 1)                                AS stepping_chip_hours,
  ROUND(w.busy_chip_hours, 1)                                    AS busy_chip_hours,
  -- Chip-hours the accelerator was actively processing. Sits between pod and
  -- busy: the gap above it is capacity handed to a pod that did nothing, the
  -- gap below it is a chip that worked without doing dense arithmetic.
  ROUND(w.duty_chip_hours, 1)                                    AS duty_chip_hours,
  ROUND(w.flops_chip_hours, 1)                                   AS flops_chip_hours,
  -- Every ratio is NULL below 0.9 day coverage, rather than published small.
  --
  -- The chip-hour columns above are honest partial sums; a ratio built on a
  -- partial denominator is not approximately right, it is arbitrary. Observed
  -- while reviewing this model: the scheduled refresh was still running an
  -- image without the reservation collector, so paid_chip_hours stopped at
  -- 2026-09-03 06:29 while busy_chip_hours kept accruing to 09-04 01:32, and
  -- 2026-09-03 published 60.64% chip utilisation against a real figure near
  -- 18%. day_coverage recorded 0.271 that whole time and was simply read past.
  -- Suppressing the ratio makes that unreadable rather than merely documented.
  IF(c.day_coverage < 0.9, NULL,
     ROUND(100 * SAFE_DIVIDE(c.scheduled_chip_hours, c.paid_chip_hours), 2))
                                                                 AS reservation_utilization_pct,
  IF(c.day_coverage < 0.9
       OR IFNULL(w.metric_coverage, 0) < 0.9, NULL,     ROUND(100 * SAFE_DIVIDE(w.busy_chip_hours, c.paid_chip_hours), 2))
                                                                 AS chip_utilization_pct,
  -- ---------------------------------------------------------------------
  -- The four named efficiency ratios, gated here rather than at each reader.
  --
  -- Every one of them was previously computed in the dashboard, once per tile
  -- and again per trend line, each carrying its own copy of the gate
  -- expression. Four ratios x two surfaces is eight places for the threshold to
  -- drift, and a reader cannot tell a gated NULL from a missing row. Computing
  -- them here means a ratio that fails its coverage test is NULL everywhere at
  -- once, and fin_export carries them to downstream systems already gated.
  --
  -- global_*      divide by paid_chip_hours      -- what was bought
  -- *_in_vm       divide by scheduled_chip_hours -- what was handed to a VM
  --
  -- The pair differs only in denominator, and
  --   global_X = X_in_vm x reservation_utilization
  -- holds by construction: the scheduled term cancels. Verified on 30 days --
  -- 80.42% x 95.18% = 76.54% and 34.60% x 95.18% = 32.93%.
  --
  -- "Utilisation" is duty_cycle, not tensorcore_utilization, matching the
  -- Cloud Monitoring dashboard this replaces: its panel was titled
  -- "芯片利用率 % (utilized/scheduled, by type)" over duty_cycle, while
  -- tensorcore appeared separately as "Per-job MFU 代理". chip_utilization_pct
  -- above keeps the tensorcore reading under its own name.
  IF(c.day_coverage < 0.9
       OR IFNULL(w.metric_coverage, 0) < 0.9, NULL,     ROUND(100 * SAFE_DIVIDE(w.pod_chip_hours, c.paid_chip_hours), 2))
                                                                 AS global_allocate_rate,
  IF(c.day_coverage < 0.9
       OR IFNULL(w.metric_coverage, 0) < 0.9, NULL,     ROUND(100 * SAFE_DIVIDE(w.duty_chip_hours, c.paid_chip_hours), 2))
                                                                 AS global_tpu_utils,
  IF(c.day_coverage < 0.9
       OR IFNULL(w.metric_coverage, 0) < 0.9, NULL,     ROUND(100 * SAFE_DIVIDE(w.pod_chip_hours, c.scheduled_chip_hours), 2))
                                                                 AS tpu_allocate_rate_in_vm,
  IF(c.day_coverage < 0.9
       OR IFNULL(w.metric_coverage, 0) < 0.9, NULL,     ROUND(100 * SAFE_DIVIDE(w.duty_chip_hours, c.scheduled_chip_hours), 2))
                                                                 AS tpu_utils_in_vm,
  -- bf16 peak
  IF(c.day_coverage < 0.9 OR IFNULL(w.work_coverage, 0) < 0.9, NULL,
     ROUND(100 * SAFE_DIVIDE(w.flops_chip_hours, c.paid_chip_hours), 2))
                                                                 AS mfu_pct,
  -- (paid - busy) x price, and suppressed on the same condition as the ratios
  -- it is derived from. Left unsuppressed it was the most damaging number on
  -- the page: 2026-08-25 has work_coverage 0.38 and reported 100.0% of that
  -- day's spend as idle, which says the whole day was wasted when the truth is
  -- that its work could not be attributed to a capacity class.
  IF(c.day_coverage < 0.9
       OR IFNULL(w.metric_coverage, 0) < 0.9, NULL,     ROUND((c.paid_chip_hours - COALESCE(w.busy_chip_hours, 0))
           * (SELECT usd_per_chip_hour FROM price), 0))          AS idle_usd,
  ROUND(c.paid_chip_hours * (SELECT usd_per_chip_hour FROM price), 0) AS paid_usd,
  -- The rate travels with the money so any figure here can be re-derived, and
  -- so a change of rate card is visible rather than silent.
  (SELECT usd_per_chip_hour FROM price)                          AS rate_usd_per_chip_hour,
  -- Trust markers, published beside the numbers rather than in a footnote.
  c.day_coverage,
  -- Share of that day's pods that could be attributed to a capacity class.
  --
  -- It gates mfu_pct alone. Every other ratio on this row is measured from the
  -- node-scoped accelerator series, which carries no pod and therefore needs no
  -- pod-to-pool mapping; MFU is the exception because its numerator comes from
  -- the training log and is attributed per job.
  w.work_coverage,
  -- How much of the day the accelerator metric covers. Gates chip_utilization
  -- and idle_usd, which are built from it. Deliberately does NOT gate mfu_pct:
  -- flops_chip_hours is parsed from the training log and never reads this
  -- metric, so an accelerator outage leaves MFU perfectly measurable.
  w.metric_coverage,
  -- How much of busy_chip_hours rests on the falcon assumption above, and how
  -- much is still unattributable. Both published so a reader can re-derive the
  -- conservative figure by subtracting.
  -- Chip-hours on a chip whose node was running, measured from the node-scoped
  -- accelerator series. It is the denominator of the two in-VM ratios and an
  -- independent reading of reservation/used -- the two agree hour by hour, from
  -- unrelated systems, which is what licenses reporting either.
  ROUND(w.vm_chip_hours, 1)                                      AS vm_chip_hours,
  -- Chip-hours weighted by HBM bandwidth in use. Read against duty and busy it
  -- separates a chip waiting on memory from one waiting on the network.
  ROUND(w.membw_chip_hours, 1)                                   AS membw_chip_hours,
  w.chips_seen,
  w.nodes_seen,
  -- Does this day's funnel actually nest? Every stage is measured by a different
  -- system -- reservation metrics, the accelerator agent, the training log -- so
  -- nothing structural forces stage N to sit below stage N-1, and a day where it
  -- does not is a measurement fault rather than a finding about the fleet. It is
  -- published as a column instead of being silently dropped so a consumer of
  -- fin_export can see which days were excluded and why.
  --
  -- Written 2026-09-08 after 2026-08-22 produced duty_chip_hours below
  -- busy_chip_hours: on that day 71.4% of duty samples read 0 against
  -- tensorcore's 56.1%, with both metrics covering all 24 hours.
  -- duty and stepping are checked as a pair rather than ordered against each
  -- other. They measure nearly the same thing by unrelated means -- the
  -- accelerator agent's binary occupancy signal, and the wall-clock of steps
  -- parsed out of the training log -- and over 24 days they come to 30.9% and
  -- 30.8% of paid capacity, crossing on individual days. Forcing an order
  -- between them would reject days for a disagreement of a fraction of a
  -- percent between two estimates of one quantity; that they land on top of
  -- each other is corroboration, not a fault. What must hold is that both sit
  -- inside the chain.
  (c.scheduled_chip_hours <= c.paid_chip_hours
   AND COALESCE(w.pod_chip_hours, 0) <= c.scheduled_chip_hours
   AND GREATEST(COALESCE(w.duty_chip_hours, 0),
                COALESCE(w.stepping_chip_hours, 0)) <= COALESCE(w.pod_chip_hours, 0)
   AND COALESCE(w.busy_chip_hours, 0) <= LEAST(COALESCE(w.duty_chip_hours, 0),
                                               COALESCE(w.stepping_chip_hours, 0)))
   -- flops is deliberately not checked. The funnel stopped displaying that stage
   -- on 2026-09-10, and gating a chart on a stage it does not show would drop
   -- days for a reason invisible to whoever reads it. mfu_pct keeps its own
   -- coverage gates and is still published in fin_daily and fin_export.
                                                                 AS funnel_monotonic
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
  -- Two gates, both of which a consumer needs to see. day_coverage is how much
  -- of the day the reservation metrics cover; work_coverage is how much of that
  -- day's work could be attributed to a capacity class. Any ratio or currency
  -- figure below 0.9 on either is already NULL rather than published low, so a
  -- row with a value in it has passed both -- but the columns travel with the
  -- data so a downstream system can apply a stricter bar of its own.
  day_coverage,
  work_coverage,
  metric_coverage,
  funnel_monotonic
FROM (
  SELECT day, day_coverage, work_coverage, metric_coverage, funnel_monotonic,
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
            'busy_chip_hours / paid_chip_hours; tensorcore, the MFU proxy'),
     STRUCT('global_allocate_rate', global_allocate_rate, 'percent',
            'pod_chip_hours / paid_chip_hours'),
     STRUCT('global_tpu_utils', global_tpu_utils, 'percent',
            'duty_chip_hours / paid_chip_hours = tpu_utils_in_vm * reservation_utilization_pct'),
     STRUCT('tpu_allocate_rate_in_vm', tpu_allocate_rate_in_vm, 'percent',
            'pod_chip_hours / scheduled_chip_hours; denominator is VMs brought up, NOT comparable with the global_* pair'),
     STRUCT('tpu_utils_in_vm', tpu_utils_in_vm, 'percent',
            'duty_chip_hours / scheduled_chip_hours; matches the legacy panel 芯片利用率 % (utilized/scheduled)'),
     STRUCT('mfu_pct', mfu_pct, 'percent',
            'flops_chip_hours / paid_chip_hours; bf16 peak, so fp8 jobs read ~half'),
     STRUCT('paid_usd', paid_usd, 'USD',
            'paid_chip_hours * dim_tpu_price.usd_per_chip_hour (Commit3Yr)'),
     STRUCT('idle_usd', idle_usd, 'USD',
            '(paid_chip_hours - busy_chip_hours) * usd_per_chip_hour')
    ] AS metrics
  FROM mlobs_core.fin_daily
), UNNEST(metrics);
