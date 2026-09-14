-- Keep the ML Diagnostics landing tables at one row per object.
--
-- collect/mldiag_poller.py re-reads every run and every monitored event on each
-- pass and appends all of them, so the raw tables are an append log of a state
-- that barely changes. Measured 2026-09-14 before the first compaction:
--
--   mldiag_runs     19,714,054 rows for  25,255 distinct names   780x   11.47 GiB
--   mldiag_events    1,721,694 rows for   8,316 distinct names   207x    1.70 GiB
--
-- 13.2 GiB holding 33,571 distinct objects. Compacted, the same two tables are
-- 23.8 MiB, and every downstream figure is unchanged to the row: dim_mlrun
-- 25,255, fact_mlrun_event 1,671 over seven days, 2 event types. That equality
-- is not luck -- both views already take ROW_NUMBER() ... ORDER BY ingested_at
-- DESC WHERE rn = 1, so only the newest copy of each name was ever readable.
-- Nothing reads the payload history, checked across model/, serve/ and
-- collect/; build_v_sink_logs.py explicitly denies both tables.
--
-- The real fix is for the poller to write only what changed, which needs it to
-- read current state before writing. Until then this bounds the cost, and it
-- bounds it where the damage is -- an 11 GiB table is also an 11 GiB scan for
-- anyone who queries the raw layer directly.
--
-- **The guard is free.** __TABLES__ is table metadata, not table data: it
-- reports row_count without scanning a byte. So this file runs on every refresh
-- and costs nothing on the runs where it does nothing. Counting DISTINCT name
-- instead would have scanned the name column 48 times a day to decide not to
-- act.
--
-- Thresholds are set so compaction fires every day or two rather than every
-- pass: the poller adds roughly 1.2M run rows and 0.4M event rows a day, so
-- these trip after about 1.5 days and 1 day respectively, each costing a scan
-- of about a gigabyte. Lower thresholds would rewrite the table for a handful
-- of duplicates; higher ones let the scan cost grow before paying it down.

DECLARE runs_rows   INT64 DEFAULT 0;
DECLARE events_rows INT64 DEFAULT 0;

SET runs_rows = (
  SELECT IFNULL(MAX(row_count), 0) FROM mlobs_raw.__TABLES__
  WHERE table_id = 'mldiag_runs');
SET events_rows = (
  SELECT IFNULL(MAX(row_count), 0) FROM mlobs_raw.__TABLES__
  WHERE table_id = 'mldiag_events');

IF runs_rows > 2000000 THEN
  -- Partitioning and clustering have to be restated. CREATE OR REPLACE refuses
  -- to change either, and omitting CLUSTER BY name counts as changing it:
  -- "Cannot replace a table with a different partitioning spec", which is how
  -- the first attempt at this failed.
  CREATE OR REPLACE TABLE mlobs_raw.mldiag_runs
  PARTITION BY DATE(ingested_at)
  CLUSTER BY name AS
  SELECT * EXCEPT(_rn) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY name ORDER BY ingested_at DESC) AS _rn
    FROM mlobs_raw.mldiag_runs)
  WHERE _rn = 1;
END IF;

IF events_rows > 500000 THEN
  CREATE OR REPLACE TABLE mlobs_raw.mldiag_events
  PARTITION BY DATE(ingested_at)
  CLUSTER BY name AS
  SELECT * EXCEPT(_rn) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY name ORDER BY ingested_at DESC) AS _rn
    FROM mlobs_raw.mldiag_events)
  WHERE _rn = 1;
END IF;
