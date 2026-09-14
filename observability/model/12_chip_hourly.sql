-- chip_hourly: the wide table, one row per chip per hour.
--
-- The shape the customer consumes. Everything a reader might want about one
-- chip in one hour is on the row -- where it is, which pool and reservation
-- paid for it, what ran on it, and how hard it worked -- so answering a
-- question needs no joins.
--
-- A straight aggregate of fact_chip: twelve five-minute rows to one hour for
-- recent days, one 3600-second row for days past Cloud Monitoring's six-week
-- full-resolution window. It adds no measurement of its own; the reason it
-- exists rather than a view is that a view over 4.6M rows is re-read on every
-- query, while this is 12k rows a day and can be scanned whole.
--
-- Numerator and denominator are both here. `vm_slots` is the five-minute-
-- equivalent time in which the chip's node was up, which is the denominator of
-- the two in-VM ratios; `pod_slots` is the part a pod held. That works
-- because the node-scoped accelerator metrics report for a chip whether or not
-- anything is scheduled on it, so an idle chip is a row of zeroes rather than
-- an absent row.
--
-- The one quantity that cannot live here is paid capacity. A reserved chip with
-- no VM produces no series anywhere -- there is no node, no container, nothing
-- to count -- so it cannot have a row keyed on a chip that does not exist. That
-- denominator is per reservation and lives in fin_capacity_daily.
--
-- chip_id is <gce-instance-id>-<0..3>, so instance_id is a substring rather
-- than a lookup.
--
-- Hours are partial at the edges of a run and while a node is coming or going;
-- vm_slots says how much of the hour was actually observed, and 12 is a full
-- one. Everything here weights by fact_chip.interval_s rather than counting
-- rows, so the two source resolutions produce the same chip-hours.

CREATE TABLE IF NOT EXISTS mlobs_core.chip_hourly
(
  hour             TIMESTAMP NOT NULL,
  chip_id          STRING NOT NULL,
  instance_id      STRING,
  chip_index       INT64,
  node_name        STRING,
  cluster_name     STRING,
  location         STRING,
  node_pool        STRING,
  capacity_class   STRING,
  reservation_name STRING,
  machine_type     STRING,
  tpu_topology     STRING,
  -- The workload that held the chip for most of the hour. A chip handed from
  -- one job to another inside an hour is attributed to whichever held it for
  -- more slots; pod_slots says how much of the hour was occupied at all.
  pod_name         STRING,
  job_key          STRING,
  job_family       STRING,
  -- Five-minute-equivalents out of 12. vm_slots is the in-VM denominator.
  vm_slots         INT64,
  pod_slots        INT64,
  -- Time-weighted means over the slots that reported, 0-100.
  duty_pct         FLOAT64,
  tensorcore_pct   FLOAT64,
  membw_pct        FLOAT64,
  -- The same three as chip-hours, so a reader can sum across chips without
  -- reweighting. chip_hours = pct/100 * slots/12 = pct/100 * interval_s/3600.
  vm_chip_hours    FLOAT64,
  pod_chip_hours   FLOAT64,
  duty_chip_hours  FLOAT64,
  busy_chip_hours  FLOAT64,
  membw_chip_hours FLOAT64
)
PARTITION BY DATE(hour)
CLUSTER BY chip_id, job_key;

BEGIN TRANSACTION;

DELETE FROM mlobs_core.chip_hourly
WHERE hour >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 4 DAY);

INSERT INTO mlobs_core.chip_hourly
WITH src AS (
  SELECT * FROM mlobs_core.fact_chip
  WHERE slot >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 4 DAY)
),
-- The job holding the chip longest in the hour -- ranked on summed interval_s
-- rather than row count, because a row is no longer a fixed amount of time.
-- Ties break on the name so a rerun produces the same row.
owner AS (
  SELECT hour, chip_id, pod_name, job_key, job_family
  FROM (
    SELECT hour, chip_id, pod_name, job_key, job_family,
           ROW_NUMBER() OVER (PARTITION BY hour, chip_id
                              ORDER BY n DESC, pod_name) AS rn
    FROM (
      SELECT TIMESTAMP_TRUNC(slot, HOUR) AS hour,
             chip_id, pod_name, job_key, job_family, SUM(interval_s) AS n
      FROM src
      WHERE pod_name IS NOT NULL
      GROUP BY hour, chip_id, pod_name, job_key, job_family
    )
  )
  WHERE rn = 1
)
SELECT
  TIMESTAMP_TRUNC(s.slot, HOUR) AS hour,
  s.chip_id,
  ANY_VALUE(s.instance_id),
  ANY_VALUE(s.chip_index),
  ANY_VALUE(s.node_name),
  ANY_VALUE(s.cluster_name),
  ANY_VALUE(s.location),
  ANY_VALUE(s.node_pool),
  ANY_VALUE(s.capacity_class),
  ANY_VALUE(s.reservation_name),
  ANY_VALUE(s.machine_type),
  ANY_VALUE(s.tpu_topology),
  ANY_VALUE(o.pod_name),
  ANY_VALUE(o.job_key),
  ANY_VALUE(o.job_family),
  -- Slot counts are expressed in five-minute units regardless of the source
  -- resolution, so "12 is a full hour" holds for a historical row built from a
  -- single 3600-second sample exactly as it does for twelve 300-second ones.
  CAST(ROUND(SUM(s.interval_s) / 300.0) AS INT64)  AS vm_slots,
  CAST(ROUND(SUM(IF(s.pod_name IS NULL, 0, s.interval_s)) / 300.0) AS INT64)
                                                   AS pod_slots,
  -- Time-weighted, not a plain mean: a 3600-second row must not count the same
  -- as a 300-second one. Each denominator counts only the rows that reported
  -- that metric, which is what AVG did before.
  ROUND(SAFE_DIVIDE(SUM(s.duty_pct * s.interval_s),
                    SUM(IF(s.duty_pct IS NULL, 0, s.interval_s))), 2) AS duty_pct,
  ROUND(SAFE_DIVIDE(SUM(s.tensorcore_pct * s.interval_s),
                    SUM(IF(s.tensorcore_pct IS NULL, 0, s.interval_s))), 2) AS tensorcore_pct,
  ROUND(SAFE_DIVIDE(SUM(s.membw_pct * s.interval_s),
                    SUM(IF(s.membw_pct IS NULL, 0, s.interval_s))), 2) AS membw_pct,
  ROUND(SUM(s.interval_s) / 3600, 4)               AS vm_chip_hours,
  ROUND(SUM(IF(s.pod_name IS NULL, 0, s.interval_s)) / 3600, 4) AS pod_chip_hours,
  ROUND(SUM(s.duty_pct       * s.interval_s) / 100 / 3600, 4) AS duty_chip_hours,
  ROUND(SUM(s.tensorcore_pct * s.interval_s) / 100 / 3600, 4) AS busy_chip_hours,
  ROUND(SUM(s.membw_pct      * s.interval_s) / 100 / 3600, 4) AS membw_chip_hours
FROM src s
LEFT JOIN owner o
  ON o.hour = TIMESTAMP_TRUNC(s.slot, HOUR) AND o.chip_id = s.chip_id
GROUP BY hour, s.chip_id;

COMMIT TRANSACTION;
