-- fact_notification: the delivery ledger.
--
-- Replaces the last_seen.json blob the old poller kept in GCS. Deduplication
-- becomes a query rather than a file, and two questions that were previously
-- unanswerable become one SELECT: what did we decide not to send and why, and
-- was anyone actually told about this incident.
--
-- A row is written for every decision, including suppressions, because "no
-- message arrived" has two very different causes -- the rule said no, or the
-- pipeline never saw the event -- and only a recorded suppression tells them
-- apart.
CREATE TABLE IF NOT EXISTS mlobs_core.fact_notification
(
  notified_at   TIMESTAMP NOT NULL,
  incident_uid  STRING,
  kind          STRING,
  category      STRING,
  state         STRING,
  target_kind   STRING,
  target        STRING,
  severity      STRING,
  title         STRING,
  reason        STRING,
  affected_jobs ARRAY<STRING>,
  would_notify  BOOL,
  rule          STRING,
  -- sent | dry_run | suppressed | failed
  status        STRING,
  error         STRING
)
PARTITION BY DATE(notified_at)
CLUSTER BY kind, status;
