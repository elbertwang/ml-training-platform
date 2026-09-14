-- fact_chip: one row per chip per five minutes. The atomic grain.
--
-- Everything above this file is an aggregate of it -- the hourly wide table the
-- customer consumes, the daily finance sheet, the fleet-level funnel. That is
-- the point. Three tables previously derived the same five quantities straight
-- from the metric samples, each with its own weighting rule, and they disagreed
-- by 13-17%: one integrated the gap to the previous sample, another counted
-- fixed buckets, and reconciling them meant reasoning about which was right for
-- every discrepancy. Deriving them all from one row set makes the question
-- disappear rather than answering it.
--
-- Five minutes is the floor. Every input is collected with ALIGN_MEAN at 300s,
-- and compute.googleapis.com/reservation/used returns identical points whether
-- asked for 60s or 300s alignment, so the denominator cannot go finer either.
--
-- Grain is (slot, chip_id). chip_id is the accelerator_id from the node-scoped
-- metrics, spelled <gce-instance-id>-<0..3>: the prefix is literally the GCE
-- instance id of the node, verified against compute instances describe, so the
-- chip-to-instance mapping needs no lookup table.
--
-- Node-scoped, not container-scoped. The node series exists for every chip on
-- every running node whether or not a pod is on it, which is what makes
-- "a chip whose VM is up" a measurable quantity rather than an inference. One
-- chip yields one reading; the container series attributes a chip to whichever
-- container claims it, so a pod handover briefly reports the same silicon
-- twice. Where a chip carries a single container series the two scopes agree to
-- four decimal places.
--
-- occupied comes from the container scope, because that is the only side that
-- knows whose work it was. The two spell accelerator_id identically, so the
-- match is exact.

CREATE TABLE IF NOT EXISTS mlobs_core.fact_chip
(
  slot          TIMESTAMP NOT NULL,
  chip_id       STRING NOT NULL,
  instance_id   STRING,
  chip_index    INT64,
  node_name     STRING,
  cluster_name  STRING,
  location      STRING,
  -- Present whenever the node resolves to a pool. Falcon deletes its pools
  -- within the job, so older rows carry NULL; the column is published rather
  -- than used as a filter, because every TPU pool in this project that resolves
  -- is reserved.
  node_pool     STRING,
  capacity_class STRING,
  reservation_name STRING,
  machine_type  STRING,
  tpu_topology  STRING,
  -- The workload on this chip in this slot, from the container scope. NULL
  -- means the chip's node was up with nothing scheduled on it.
  pod_name      STRING,
  job_key       STRING,
  job_family    STRING,
  -- Percentages as reported, 0-100. Chip-hours are (pct/100 * interval_s/3600)
  -- and are left to the reader so this table stays additive in one obvious way.
  -- The instance mean, repeated across that instance's four chip rows. See the
  -- duty_inst note below: duty_cycle cannot be keyed to a physical chip.
  duty_pct      FLOAT64,
  tensorcore_pct FLOAT64,
  membw_pct     FLOAT64,
  -- How many seconds this row stands for. 300 for everything this file writes.
  --
  -- It is a column rather than a constant because Cloud Monitoring downsamples:
  -- data older than six weeks is only served at 600s, so the history loaded by
  -- 11h_fact_chip_history.sql carries 3600. Every consumer therefore weights by
  -- interval_s instead of counting rows. Counting rows was correct while one
  -- resolution existed and would have silently halved every historical
  -- numerator the moment a second one arrived -- no error, just wrong totals.
  interval_s    INT64
)
PARTITION BY DATE(slot)
CLUSTER BY chip_id, job_key;

BEGIN TRANSACTION;

DELETE FROM mlobs_core.fact_chip
WHERE slot >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 4 DAY);

INSERT INTO mlobs_core.fact_chip
WITH
-- Pivot the three node metrics onto one row per chip per slot. AVG collapses
-- the case where collection wrote two samples into one slot; after the phase
-- snap in collect/metrics_exporter.py that is rare, and averaging is right
-- either way for a level.
-- The chip axis comes from tensorcore and memory-bandwidth, which number
-- accelerators 0-3 within the host: 128 instances, 512 chips, exactly 4.00 per
-- instance, and the same spelling the container-scoped series uses.
node AS (
  SELECT
    TIMESTAMP_TRUNC(point_time, MINUTE) -
      MAKE_INTERVAL(minute => MOD(EXTRACT(MINUTE FROM point_time), 5)) AS slot,
    JSON_VALUE(metric_labels,   '$.accelerator_id') AS chip_id,
    ANY_VALUE(JSON_VALUE(resource_labels, '$.node_name'))    AS node_name,
    ANY_VALUE(JSON_VALUE(resource_labels, '$.cluster_name')) AS cluster_name,
    ANY_VALUE(JSON_VALUE(resource_labels, '$.location'))     AS location,
    ANY_VALUE(JSON_VALUE(metric_labels,   '$.tpu_topology')) AS tpu_topology,
    AVG(IF(metric_type LIKE '%/tensorcore_utilization', value, NULL))       AS tensorcore_pct,
    AVG(IF(metric_type LIKE '%/memory_bandwidth_utilization', value, NULL)) AS membw_pct
  FROM mlobs_raw.metric_samples
  WHERE point_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 4 DAY)
    AND metric_type IN (
      'kubernetes.io/node/accelerator/tensorcore_utilization',
      'kubernetes.io/node/accelerator/memory_bandwidth_utilization')
  GROUP BY slot, chip_id
),
-- duty_cycle is carried at the instance, not the chip.
--
-- It numbers accelerators by slice coordinate rather than by position in the
-- host -- ids like <instance>-4, -5, -12, -13 against tensorcore's -0 to -3 --
-- and the two spaces do not correspond one to one: in a single sampled instant
-- tensorcore and memory-bandwidth each reported 512 chips across 128 instances,
-- exactly 4.00 apiece, while duty reported the same 512 chips spread over 120
-- instances, 4.27 apiece. There is no evidence in the data for which physical
-- chip a given duty coordinate names.
--
-- A NULL here means the instance emitted no duty series at all, and it is left
-- NULL rather than filled. The gap is not random: over seven days 26% of
-- chip-slots have no duty reading, and on those the tensorcore average is
-- 0.22% against 22.16% where duty is present. duty_cycle is simply not reported
-- for an accelerator that never activates, so the missing rows are the idle
-- ones and summing NULL as zero is the correct reading. Filling them with the
-- instance mean would invent activity on chips that had none.
--
-- So the instance mean is attached to each of that instance's chip rows. Summed
-- over an instance or anything larger the result is exact -- four rows times the
-- mean is the instance total -- and only a comparison between two chips of the
-- same host is an approximation. Joining on the raw id instead would split one
-- physical chip into two rows, which is how a first version of this file
-- produced 970 chips in a slot that holds 512.
duty_inst AS (
  SELECT
    TIMESTAMP_TRUNC(point_time, MINUTE) -
      MAKE_INTERVAL(minute => MOD(EXTRACT(MINUTE FROM point_time), 5)) AS slot,
    SPLIT(JSON_VALUE(metric_labels, '$.accelerator_id'), '-')[OFFSET(0)] AS instance_id,
    AVG(value) AS duty_pct
  FROM mlobs_raw.metric_samples
  WHERE point_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 4 DAY)
    AND metric_type = 'kubernetes.io/node/accelerator/duty_cycle'
  GROUP BY slot, instance_id
),
-- Which pod held the chip in that slot. A handover puts two pods in one slot;
-- the one with more samples wins, and ties break on the name so the result is
-- deterministic across reruns.
occupied AS (
  SELECT slot, chip_id, pod_name
  FROM (
    SELECT slot, chip_id, pod_name,
           ROW_NUMBER() OVER (PARTITION BY slot, chip_id
                              ORDER BY n DESC, pod_name) AS rn
    FROM (
      SELECT slot, chip_id, pod_name, COUNT(*) AS n
      FROM (
        SELECT
          TIMESTAMP_TRUNC(point_time, MINUTE) -
            MAKE_INTERVAL(minute => MOD(EXTRACT(MINUTE FROM point_time), 5)) AS slot,
          chip_id, pod_name
        FROM mlobs_core.fact_metric
        WHERE point_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 4 DAY)
          AND metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
      )
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
  300 AS interval_s
FROM node n
LEFT JOIN duty_inst du
  ON du.slot = n.slot AND du.instance_id = SPLIT(n.chip_id, '-')[OFFSET(0)]
LEFT JOIN occupied o ON o.slot = n.slot AND o.chip_id = n.chip_id
LEFT JOIN mlobs_core.dim_pod p ON p.pod_name = o.pod_name
-- Deduped to one row per hash: dim_node_pool is keyed on (cluster, ig_hash) and
-- the same group can appear under two clusters, which would otherwise fan a
-- chip row into two.
LEFT JOIN (
  SELECT ig_hash,
         ANY_VALUE(node_pool)        AS node_pool,
         ANY_VALUE(capacity_class)   AS capacity_class,
         ANY_VALUE(reservation_name) AS reservation_name,
         ANY_VALUE(machine_type)     AS machine_type
  FROM mlobs_core.dim_node_pool GROUP BY ig_hash
) np ON np.ig_hash = mlobs_core.node_ig_hash(n.node_name);

COMMIT TRANSACTION;
