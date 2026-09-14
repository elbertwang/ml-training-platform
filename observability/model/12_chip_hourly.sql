-- chip_hourly: the wide table, one row per chip per hour.
--
-- The shape the customer consumes. Everything a reader might want about one
-- chip in one hour is on the row -- where it is, which pool and reservation
-- paid for it, what ran on it, and how hard it worked -- so answering a
-- question needs no joins.
--
-- A straight aggregate of fact_chip, twelve five-minute rows to one hour. It
-- adds no measurement of its own; the reason it exists rather than a view is
-- that a view over 4.6M rows is re-read on every query, while this is 12k rows
-- a day and can be scanned whole.
--
-- Numerator and denominator are both here. `vm_slots` counts the five-minute
-- slots in which the chip's node was up, which is the denominator of the two
-- in-VM ratios; `pod_slots` counts those where a pod held it. That works
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
-- one.

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
  -- Slots out of 12. vm_slots is the denominator of the in-VM ratios.
  vm_slots         INT64,
  pod_slots        INT64,
  -- Time-weighted means over the slots that reported, 0-100.
  duty_pct         FLOAT64,
  tensorcore_pct   FLOAT64,
  membw_pct        FLOAT64,
  -- The same three as chip-hours, so a reader can sum across chips without
  -- reweighting. chip_hours = pct/100 * slots/12.
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
-- The job holding the chip for the most slots in the hour. Ties break on the
-- name so a rerun produces the same row.
owner AS (
  SELECT hour, chip_id, pod_name, job_key, job_family
  FROM (
    SELECT hour, chip_id, pod_name, job_key, job_family,
           ROW_NUMBER() OVER (PARTITION BY hour, chip_id
                              ORDER BY n DESC, pod_name) AS rn
    FROM (
      SELECT TIMESTAMP_TRUNC(slot, HOUR) AS hour,
             chip_id, pod_name, job_key, job_family, COUNT(*) AS n
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
  COUNT(*)                                        AS vm_slots,
  COUNTIF(s.pod_name IS NOT NULL)                 AS pod_slots,
  ROUND(AVG(s.duty_pct), 2)                       AS duty_pct,
  ROUND(AVG(s.tensorcore_pct), 2)                 AS tensorcore_pct,
  ROUND(AVG(s.membw_pct), 2)                      AS membw_pct,
  ROUND(COUNT(*) / 12.0, 4)                       AS vm_chip_hours,
  ROUND(COUNTIF(s.pod_name IS NOT NULL) / 12.0, 4) AS pod_chip_hours,
  ROUND(SUM(s.duty_pct)       / 100 / 12.0, 4)    AS duty_chip_hours,
  ROUND(SUM(s.tensorcore_pct) / 100 / 12.0, 4)    AS busy_chip_hours,
  ROUND(SUM(s.membw_pct)      / 100 / 12.0, 4)    AS membw_chip_hours
FROM src s
LEFT JOIN owner o
  ON o.hour = TIMESTAMP_TRUNC(s.slot, HOUR) AND o.chip_id = s.chip_id
GROUP BY hour, s.chip_id;

COMMIT TRANSACTION;
