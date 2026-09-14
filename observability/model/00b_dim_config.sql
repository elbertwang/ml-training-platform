-- dim_config: the handful of deployment facts the model cannot infer.
--
-- One row. job_hub reads it to build console deep links and to decide whether a
-- job's logs are still inside the retention window -- a link to Logs Explorer
-- for a job older than the bucket keeps is a link to an empty page, and saying
-- so up front is better than letting someone click it.
--
-- This existed as a hand-created table for weeks and was not in the repository,
-- which meant a fresh project could not build job_hub and nothing said why. It
-- was also deleted during an orphan sweep on 2026-09-14 -- the audit reported it
-- as unreferenced because the script filtered its own results with an empty
-- grep pattern -- and 08_views broke until it was restored. Both problems have
-- the same cause: a dependency that exists only in someone's shell history.
--
-- CREATE TABLE IF NOT EXISTS plus a MERGE, so re-running is safe and a changed
-- retention updates in place rather than duplicating the row.
CREATE TABLE IF NOT EXISTS mlobs_core.dim_config
(
  project_id          STRING,
  -- The _Default bucket's retention. Logs older than this are gone from Logs
  -- Explorer regardless of what the model still holds.
  log_retention_days  INT64
);

MERGE mlobs_core.dim_config T
USING (SELECT 'tpu-for-training' AS project_id, 30 AS log_retention_days) S
ON T.project_id = S.project_id
WHEN MATCHED THEN UPDATE SET log_retention_days = S.log_retention_days
WHEN NOT MATCHED THEN INSERT (project_id, log_retention_days)
VALUES (S.project_id, S.log_retention_days);
