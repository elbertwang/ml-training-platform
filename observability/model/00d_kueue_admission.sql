-- Kueue admission decisions, recovered from Log Analytics.
--
-- The Log Router sink cannot carry these and never will. Kueue emits
-- jsonPayload.clusterQueue as a string from one code path and as an object from
-- another, and the same is true of rootCohort, queue and workload. A BigQuery
-- sink infers a typed schema once and then rejects whatever disagrees, in both
-- directions: measured 2026-09-14, mlobs_raw.export_errors held 226,058 rows
-- over 13 days, 165,494 of them "cannot convert std::string to a record field"
-- and 60,567 "this field is not a record". Both shapes occur in the same hour,
-- on the same field, in the same namespace -- 47 "Attempting to schedule
-- workload" with clusterQueue as an object alongside 27 "Workload couldn't be
-- admitted" with it as a string, in one two-hour window. No single column type
-- accepts both, so this is not a misconfiguration to fix.
--
-- **What that costs is not a fraction, it is a category.** Comparing what lands
-- against what is dropped, per message, the reconciliation bookkeeping arrives
-- intact and every admission decision is lost at exactly 100%: "Attempting to
-- schedule workload", "Workload re-queued", "Workload couldn't be admitted",
-- "requires preemption, but there are no candidate workloads", "successfully
-- admitted and assigned flavors". mlobs_core.fact_event held 16,127 kueue rows
-- for 2026-09-13 and none of them said why anything waited. The table looked
-- healthy, which is why this went unnoticed.
--
-- Log Analytics has all of it. In the defaultLink linked dataset json_payload
-- is a native BigQuery JSON column -- schema-free, so no conflict is possible --
-- and both shapes are present and readable. The type variance becomes a
-- COALESCE at read time, which is what v_sink_logs already does everywhere else.
--
-- **Not fixed with a sink exclusion.** The obvious move is to exclude these
-- entries so export_errors stops churning, and the obvious filter --
-- jsonPayload.level matching Kueue's debug verbosity -- would have dropped
-- 97,671 entries that currently land successfully on a single day. The failing
-- entries are not distinguished by level but by whether they carry the
-- contested fields at all: of 6,302 kueue entries in a sampled window, 5,244
-- carry none of them and 626 would fail. The sink is left alone and the loss is
-- recovered here instead.
--
-- Cost and cadence. One day of the linked dataset scans 22.5 GiB, about $0.14,
-- and yields roughly 6,000 decisions. The guard below advances one day per run
-- and only when the watermark is more than a day behind, so the steady state is
-- one scan a day; a cold start walks forward one day per refresh until it
-- catches up with Log Analytics' 30-day retention.
--
-- This table deliberately has no `resource` column. model/build_v_sink_logs.py
-- unions anything in mlobs_raw carrying both `resource` and `timestamp`, and
-- 04_fact_event.sql would then count every row here twice -- once through
-- v_sink_logs' app_error branch and once through the branch added for it. The
-- DENY list there names this table as well; either guard alone is enough and
-- both are cheap.

DECLARE wm TIMESTAMP;
DECLARE win_end TIMESTAMP;


CREATE TABLE IF NOT EXISTS mlobs_raw.kueue_admission
(
  event_time       TIMESTAMP,
  insert_id        STRING,
  msg              STRING,
  -- Normalised at read time from whichever shape the emitting code path used.
  cluster_queue    STRING,
  root_cohort      STRING,
  parent_cohort    STRING,
  workload         STRING,
  workload_ns      STRING,
  queue            STRING,
  scheduling_cycle INT64,
  caller           STRING,
  cluster_name     STRING,
  ingested_at      TIMESTAMP
)
PARTITION BY DATE(event_time)
CLUSTER BY msg, workload;

-- The watermark is its own row, not MAX(event_time).
--
-- Deriving it from the data cannot advance past a window that legitimately holds
-- nothing, and the first window did: kueue-system was logging on 2026-08-16 but
-- emitted no admission decisions until 08-20, so the first run inserted zero
-- rows, left MAX(event_time) NULL, and would have re-read the same empty day on
-- every refresh forever.
CREATE TABLE IF NOT EXISTS mlobs_raw.kueue_admission_wm (watermark TIMESTAMP);

-- Log Analytics keeps 30 days. Seeding at 29 leaves a day of margin so the first
-- window is not already half expired.
INSERT INTO mlobs_raw.kueue_admission_wm (watermark)
-- FROM UNNEST, because BigQuery rejects a WHERE on a query with no FROM.
SELECT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 29 DAY)
FROM UNNEST([1])
WHERE NOT EXISTS (SELECT 1 FROM mlobs_raw.kueue_admission_wm);

SET wm = (SELECT MAX(watermark) FROM mlobs_raw.kueue_admission_wm);

-- One day at a time, and never the hour still being written: the linked dataset
-- orders on receiveTimestamp, so the tail of the current hour arrives late and a
-- window that included it would leave a hole the watermark then skips past.
SET win_end = LEAST(TIMESTAMP_ADD(wm, INTERVAL 1 DAY),
                    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR));

IF wm < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR) THEN
  -- Clear the window before writing it, so re-running a range repairs rather
  -- than duplicates. The watermark makes that unnecessary in normal operation
  -- and cheap to have when someone rewinds it by hand.
  DELETE FROM mlobs_raw.kueue_admission
  WHERE event_time > wm AND event_time <= win_end;

  INSERT INTO mlobs_raw.kueue_admission
    (event_time, insert_id, msg, cluster_queue, root_cohort, parent_cohort,
     workload, workload_ns, queue, scheduling_cycle, caller, cluster_name,
     ingested_at)
  SELECT
    timestamp,
    insert_id,
    JSON_VALUE(json_payload, '$.msg'),
    -- Object or scalar, whichever this code path emitted. This two-line
    -- COALESCE is the whole of what the sink could not do.
    COALESCE(JSON_VALUE(json_payload, '$.clusterQueue.name'),
             JSON_VALUE(json_payload, '$.clusterQueue')),
    COALESCE(JSON_VALUE(json_payload, '$.rootCohort.name'),
             JSON_VALUE(json_payload, '$.rootCohort')),
    COALESCE(JSON_VALUE(json_payload, '$.parentCohort.name'),
             JSON_VALUE(json_payload, '$.parentCohort')),
    COALESCE(JSON_VALUE(json_payload, '$.workload.name'),
             JSON_VALUE(json_payload, '$.workload')),
    JSON_VALUE(json_payload, '$.workload.namespace'),
    COALESCE(JSON_VALUE(json_payload, '$.queue.name'),
             JSON_VALUE(json_payload, '$.queue')),
    SAFE_CAST(JSON_VALUE(json_payload, '$.schedulingCycle') AS INT64),
    JSON_VALUE(json_payload, '$.caller'),
    JSON_VALUE(resource.labels, '$.cluster_name'),
    CURRENT_TIMESTAMP()
  FROM `tpu-for-training.defaultLink._AllLogs`
  WHERE timestamp > wm AND timestamp <= win_end
    AND log_id = 'stderr'
    AND JSON_VALUE(resource.labels, '$.namespace_name') = 'kueue-system'
    -- The decisions, not the reconciliation chatter. Everything outside this
    -- list already reaches fact_event through the sink.
    AND JSON_VALUE(json_payload, '$.msg') IN (
      'Attempting to schedule workload',
      'Workload re-queued',
      'Workload successfully admitted and assigned flavors',
      "Workload couldn't be admitted. Moving the head of this ClusterQueue to the consecutive Workload.",
      'Workload requires preemption, but there are no candidate workloads allowed for preemption',
      'Waiting for Slices to be initialized',
      'Resetting the head of the ClusterQueue',
      'Workload assumed in the cache')
  -- The source can repeat an insert_id. Five pairs arrived that way in the
  -- first 81,315 rows, both copies written by the same run -- so it is
  -- _AllLogs redelivering an entry, not this loop reading a window twice.
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insert_id ORDER BY timestamp) = 1;

  -- Advance on the window, not on what the window happened to contain.
  UPDATE mlobs_raw.kueue_admission_wm SET watermark = win_end WHERE TRUE;
END IF;
