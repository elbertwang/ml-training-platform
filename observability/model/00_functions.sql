-- Shared scalar helpers.
--
-- Every object in this directory is written with UNQUALIFIED dataset names
-- (`mlobs_core.x`, not `project.mlobs_core.x`). BigQuery resolves them against
-- the job's default project, so `bq query --project_id=<P>` deploys the whole
-- model into <P> with no templating. That is what makes the same files work in
-- both tpu-launchpad-playground and tpu-for-training.

-- The hypercomputecluster API emits RFC-3339 stamps with 9 fractional digits
-- ("2026-08-24T07:35:35.351688728Z"); BigQuery TIMESTAMP accepts at most 6 and
-- hard-errors on the rest. Trim rather than drop the row. Also maps the API's
-- year-0001 "unset" sentinel to NULL.
CREATE OR REPLACE FUNCTION mlobs_core.api_ts(s STRING)
RETURNS TIMESTAMP
AS (
  NULLIF(
    SAFE_CAST(REGEXP_REPLACE(s, r'(\.\d{1,6})\d*', r'\1') AS TIMESTAMP),
    TIMESTAMP '0001-01-01 00:00:00 UTC')
);


-- Best-effort pod -> workload name, used ONLY as a fallback for pods that have
-- Cloud Monitoring samples but no log rows (and therefore no `dim_pod` entry).
--
-- The authoritative mapping is `mlobs_core.dim_pod`, built from the GKE labels
-- `logging.gke.io/top_level_controller_name` and
-- `jobset.sigs.k8s.io/jobset-name`. Guessing from pod names is genuinely unsafe:
-- an earlier version of this function collapsed 1,292 pods onto the bare key
-- "falcon-job" because falcon emits two different pod shapes --
--   falcon-job-<id>-<index>-<hash5>   (indexed Job)
--   falcon-job-<id>-<hash5>           (non-indexed Job)
-- -- and a non-greedy `<name>-<hash10>-<hash5>` branch written for Deployments
-- ate the 10-character falcon job id as if it were a ReplicaSet hash.
--
-- So this version handles only shapes it can recognise unambiguously and
-- returns NULL otherwise. NULL is the correct answer for "I do not know"; the
-- caller can then decide to drop the row rather than silently mis-attribute it.
CREATE OR REPLACE FUNCTION mlobs_core.job_key_from_pod_fallback(pod STRING)
RETURNS STRING
AS (
  CASE
    -- JobSet child: <jobset>-worker-<n>-<index>-<hash> or <jobset>-worker-<n>
    WHEN REGEXP_CONTAINS(pod, r'-worker-\d+')
      THEN REGEXP_EXTRACT(pod, r'^(.+?)-worker-\d+')
    -- falcon indexed Job: falcon-job-<id>-<index>-<hash5>
    WHEN REGEXP_CONTAINS(pod, r'^falcon-job-[a-z0-9]+-\d+-[a-z0-9]{5}$')
      THEN REGEXP_EXTRACT(pod, r'^(falcon-job-[a-z0-9]+)-\d+-[a-z0-9]{5}$')
    -- falcon non-indexed Job: falcon-job-<id>-<hash5>
    WHEN REGEXP_CONTAINS(pod, r'^falcon-job-[a-z0-9]+-[a-z0-9]{5}$')
      THEN REGEXP_EXTRACT(pod, r'^(falcon-job-[a-z0-9]+)-[a-z0-9]{5}$')
    ELSE NULL
  END
);
