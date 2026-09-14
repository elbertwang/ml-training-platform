-- fact_chip, the part of it that predates the live collector.
--
-- Not a second derivation. This writes into the same mlobs_core.fact_chip that
-- 11_fact_chip.sql writes, with the same columns and the same meaning, so
-- chip_hourly and fin_daily keep reading one table and there is still exactly
-- one place where raw accelerator metrics become chip facts. What differs is
-- only the input: mlobs_raw.metric_hourly at 3600s instead of
-- mlobs_raw.metric_samples at 300s, because Cloud Monitoring stops serving the
-- finer resolution after six weeks. See collect/backfill_metrics_hourly.py.
--
-- Run once per range, by hand, outside refresh.sh:
--
--   sed -e "s/@@FROM@@/2026-03-11/" -e "s/@@TO@@/2026-08-11/" \
--       model/11h_fact_chip_history.sql \
--     | bq --project_id=tpu-for-training query --use_legacy_sql=false
--
-- The range must end where the live path begins. They do not overlap and
-- nothing here reconciles them: --to is exclusive and the DELETE below is
-- bounded by it, so a mistake shows up as a gap or a duplicate day rather than
-- as two silently blended resolutions.
--
-- ============================ WHAT HISTORY CANNOT HAVE ====================
--
-- Three columns are NULL for most of this range, and that is a property of the
-- sources rather than something to fix here:
--
--   job_key, job_family   dim_pod is built from GKE labels carried in container
--                         logs, and _Default retains 30 days. The mapping for
--                         June cannot be reconstructed from any channel.
--   node_pool,            dim_node_pool accumulates from snapshots and was
--   capacity_class,       backfilled as far as Cloud Asset Inventory's 35-day
--   reservation_name      configuration history allowed.
--
-- pod_name survives, because the container-scoped series carries it as a
-- resource label and Cloud Monitoring keeps it as long as it keeps the series.
-- So "was a pod on this chip" is answerable for the whole range; "whose job was
-- it" is not.
--
-- interval_s is written from the source row rather than assumed, and the source
-- measured it with ALIGN_COUNT rather than assuming a full hour. A chip whose
-- node came up at ten past the hour carries 3000, not 3600.

DECLARE range_from DATE DEFAULT DATE '@@FROM@@';
DECLARE range_to   DATE DEFAULT DATE '@@TO@@';   -- exclusive

BEGIN TRANSACTION;

DELETE FROM mlobs_core.fact_chip
WHERE DATE(slot) >= range_from AND DATE(slot) < range_to;

INSERT INTO mlobs_core.fact_chip
  (slot, chip_id, instance_id, chip_index, node_name, cluster_name, location,
   node_pool, capacity_class, reservation_name, machine_type, tpu_topology,
   pod_name, job_key, job_family, duty_pct, tensorcore_pct, membw_pct,
   interval_s, pod_interval_s)
WITH
-- The chip axis, from the two metrics that number accelerators 0-3 within the
-- host. Same rule as the live path; only the grain differs.
node AS (
  SELECT
    point_time AS slot,
    JSON_VALUE(metric_labels, '$.accelerator_id') AS chip_id,
    ANY_VALUE(JSON_VALUE(resource_labels, '$.node_name'))    AS node_name,
    ANY_VALUE(JSON_VALUE(resource_labels, '$.cluster_name')) AS cluster_name,
    ANY_VALUE(JSON_VALUE(resource_labels, '$.location'))     AS location,
    ANY_VALUE(JSON_VALUE(metric_labels,   '$.tpu_topology')) AS tpu_topology,
    AVG(IF(metric_type LIKE '%/tensorcore_utilization', value, NULL))       AS tensorcore_pct,
    AVG(IF(metric_type LIKE '%/memory_bandwidth_utilization', value, NULL)) AS membw_pct,
    -- How long the chip was actually up in this hour. tensorcore defines the
    -- chip axis so its width is authoritative; memory-bandwidth is the fallback
    -- for the rare hour where only that one reported.
    COALESCE(
      MAX(IF(metric_type LIKE '%/tensorcore_utilization', interval_s, NULL)),
      MAX(IF(metric_type LIKE '%/memory_bandwidth_utilization', interval_s, NULL))
    ) AS interval_s
  FROM mlobs_raw.metric_hourly
  WHERE DATE(point_time) >= range_from AND DATE(point_time) < range_to
    AND metric_type IN (
      'kubernetes.io/node/accelerator/tensorcore_utilization',
      'kubernetes.io/node/accelerator/memory_bandwidth_utilization')
  GROUP BY slot, chip_id
),
-- duty_cycle at the instance, not the chip: it numbers accelerators by slice
-- coordinate and the two spaces do not correspond one to one. Identical
-- reasoning to 11_fact_chip.sql, which has the measurement behind it.
duty_inst AS (
  SELECT
    point_time AS slot,
    SPLIT(JSON_VALUE(metric_labels, '$.accelerator_id'), '-')[OFFSET(0)] AS instance_id,
    AVG(value) AS duty_pct
  FROM mlobs_raw.metric_hourly
  WHERE DATE(point_time) >= range_from AND DATE(point_time) < range_to
    AND metric_type = 'kubernetes.io/node/accelerator/duty_cycle'
  GROUP BY slot, instance_id
),
-- Which pod held the chip. The live path ranks by sample count within a
-- five-minute slot; at an hourly grain the container series already collapses
-- to one point per pod per hour, so the rank is on how much of the hour each
-- pod's series covered. Ties break on the name, as there.
occupied AS (
  SELECT slot, chip_id, pod_name, held_s
  FROM (
    SELECT slot, chip_id, pod_name, held_s,
           ROW_NUMBER() OVER (PARTITION BY slot, chip_id
                              ORDER BY held_s DESC, pod_name) AS rn
    FROM (
      SELECT
        point_time AS slot,
        JSON_VALUE(metric_labels,   '$.accelerator_id') AS chip_id,
        JSON_VALUE(resource_labels, '$.pod_name')       AS pod_name,
        SUM(interval_s) AS held_s
      FROM mlobs_raw.metric_hourly
      WHERE DATE(point_time) >= range_from AND DATE(point_time) < range_to
        AND metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
        AND JSON_VALUE(resource_labels, '$.pod_name') IS NOT NULL
      GROUP BY slot, chip_id, pod_name
    )
  )
  WHERE rn = 1
)
SELECT
  n.slot,
  n.chip_id,
  SPLIT(n.chip_id, '-')[OFFSET(0)]                        AS instance_id,
  SAFE_CAST(SPLIT(n.chip_id, '-')[OFFSET(1)] AS INT64)    AS chip_index,
  n.node_name,
  n.cluster_name,
  n.location,
  np.node_pool,
  np.capacity_class,
  np.reservation_name,
  np.machine_type,
  n.tpu_topology,
  o.pod_name,
  p.job_key,
  p.job_family,
  ROUND(du.duty_pct, 2),
  ROUND(n.tensorcore_pct, 2),
  ROUND(n.membw_pct, 2),
  -- Measured, not assumed. The hour is credited to the pod only for as long as
  -- the container series actually reported the chip, capped at the time the
  -- node itself was up. Crediting the whole hour made pod_slots binary across
  -- the entire recovered range -- 0.0% of rows partially occupied from March to
  -- July against 51.9% in the live segment -- and made pod_chip_hours, and so
  -- global_allocate_rate and tpu_allocate_rate_in_vm, an upper bound there.
  n.interval_s,
  LEAST(IFNULL(o.held_s, 0), n.interval_s) AS pod_interval_s
FROM node n
LEFT JOIN duty_inst du
  ON du.slot = n.slot AND du.instance_id = SPLIT(n.chip_id, '-')[OFFSET(0)]
LEFT JOIN occupied o ON o.slot = n.slot AND o.chip_id = n.chip_id
LEFT JOIN mlobs_core.dim_pod p ON p.pod_name = o.pod_name
LEFT JOIN (
  SELECT ig_hash,
         ANY_VALUE(node_pool)        AS node_pool,
         ANY_VALUE(capacity_class)   AS capacity_class,
         ANY_VALUE(reservation_name) AS reservation_name,
         ANY_VALUE(machine_type)     AS machine_type
  FROM mlobs_core.dim_node_pool GROUP BY ig_hash
) np ON np.ig_hash = mlobs_core.node_ig_hash(n.node_name);

COMMIT TRANSACTION;
