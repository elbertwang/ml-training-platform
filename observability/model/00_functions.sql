-- Shared scalar helpers for the mlobs_core model layer.

-- The hypercomputecluster API emits RFC-3339 stamps with 9 fractional digits
-- ("2026-08-24T07:35:35.351688728Z"); BigQuery TIMESTAMP accepts at most 6 and
-- hard-errors on the rest. Trim the extra digits rather than dropping the row.
-- Also maps the API's year-0001 "unset" sentinel to NULL.
CREATE OR REPLACE FUNCTION `tpu-for-training.mlobs_core.api_ts`(s STRING)
RETURNS TIMESTAMP
AS (
  NULLIF(
    SAFE_CAST(REGEXP_REPLACE(s, r'(\.\d{1,6})\d*', r'\1') AS TIMESTAMP),
    TIMESTAMP '0001-01-01 00:00:00 UTC')
);

-- Collapse a pod name to the workload that owns it, so logs and metrics (which
-- only ever carry the pod name) can be joined to a job.
--
-- Three naming families coexist in this project and the platform has to cover
-- all of them; falcon is the current production one:
--   falcon-jobs   falcon-job-u1wm3wuha2-9-vsbfv    -> falcon-job-u1wm3wuha2
--   JobSet/MaxText  lossdif-flash-1000-r428-worker-0-x9k2m -> lossdif-flash-1000-r428
--   plain indexed Job  <name>-<index>-<hash>       -> <name>
-- The result matches `dim_mlrun.gke_workload_name`, which is the join key the
-- ML Diagnostics API reports for the same workload.
CREATE OR REPLACE FUNCTION `tpu-for-training.mlobs_core.job_key_from_pod`(pod STRING)
RETURNS STRING
AS (
  COALESCE(
    REGEXP_EXTRACT(pod, r'^(.+?)-worker-\d+'),
    REGEXP_EXTRACT(pod, r'^(.+?)-\d+-[a-z0-9]{5}$'),
    REGEXP_EXTRACT(pod, r'^(.+?)-[a-z0-9]{9,10}-[a-z0-9]{5}$'),
    pod)
);
