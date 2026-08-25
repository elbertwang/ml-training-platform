-- Job identity, in two grains.
--
-- dim_job_attempt  one row per Job object actually created (PK attempt_uid)
-- dim_job          one row per job name (PK job_key), 1:N attempts
--
-- Both grains are needed. A user thinks in job names and wants one URL per job;
-- the numbers (chip-hours, goodput, cost) only make sense per attempt, because
-- the same name is reused -- "henry-hlo-test" is 101 separate runs across seven
-- weeks, and "l3p-remat-m5-v2-256-0825-r2-worker-0" restarted 11 times in one
-- day. Summing metrics by name alone would merge unrelated runs.

CREATE OR REPLACE VIEW mlobs_core.dim_job_attempt AS
SELECT
  p.attempt_uid,
  p.job_key,
  ANY_VALUE(p.job_family)      AS job_family,
  LOGICAL_OR(p.is_job_attempt) AS is_job_attempt,
  ANY_VALUE(p.namespace_name)  AS namespace_name,
  ANY_VALUE(p.cluster_name)    AS cluster_name,
  ANY_VALUE(p.location)        AS location,
  ANY_VALUE(p.child_job_name)  AS child_job_name,
  ANY_VALUE(p.owner)           AS owner,
  ANY_VALUE(p.exp_id)          AS exp_id,
  ANY_VALUE(p.falcon_job_id)   AS falcon_job_id,
  MAX(p.jobset_restart_attempt) AS jobset_restart_attempt,
  COUNT(DISTINCT p.pod_name)   AS pods,
  COUNT(DISTINCT p.node_name)  AS nodes,
  MIN(p.first_seen)            AS first_seen,
  MAX(p.last_seen)             AS last_seen,
  TIMESTAMP_DIFF(MAX(p.last_seen), MIN(p.first_seen), SECOND) AS observed_duration_s
FROM mlobs_core.dim_pod p
WHERE p.attempt_uid IS NOT NULL
GROUP BY p.attempt_uid, p.job_key;


CREATE OR REPLACE VIEW mlobs_core.dim_job AS
WITH attempts AS (
  SELECT * FROM mlobs_core.dim_job_attempt
),
-- ML Diagnostics is enrichment, not the spine. A job name can carry several ML
-- runs for the same reason it carries several attempts, so pick the latest and
-- keep the count so the UI can say "5 runs" rather than pretend there was one.
mlrun AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      m.*,
      COUNT(*)     OVER (PARTITION BY job_key)                        AS mlrun_count,
      ROW_NUMBER() OVER (PARTITION BY job_key ORDER BY create_time DESC) AS rn
    FROM mlobs_core.dim_mlrun m
    WHERE job_key IS NOT NULL)
  WHERE rn = 1
)
SELECT
  a.job_key,
  ANY_VALUE(a.job_family)     AS job_family,
  ANY_VALUE(a.namespace_name) AS namespace_name,
  ANY_VALUE(a.cluster_name)   AS cluster_name,
  ANY_VALUE(a.location)       AS location,
  ANY_VALUE(a.owner)          AS owner,
  ANY_VALUE(a.exp_id)         AS exp_id,
  ANY_VALUE(a.falcon_job_id)  AS falcon_job_id,
  COUNT(*)                    AS attempts,
  SUM(a.pods)                 AS total_pods,
  MAX(a.nodes)                AS peak_nodes,
  MIN(a.first_seen)           AS first_seen,
  MAX(a.last_seen)            AS last_seen,
  -- enrichment
  ANY_VALUE(r.mlrun_id)       AS mlrun_id,
  ANY_VALUE(r.mlrun_location) AS mlrun_location,
  ANY_VALUE(r.run_phase)      AS run_phase,
  ANY_VALUE(r.has_smon)       AS has_smon,
  ANY_VALUE(r.mlrun_count)    AS mlrun_count,
  ANY_VALUE(r.workload_create_time) AS workload_create_time
FROM attempts a
LEFT JOIN mlrun r USING (job_key)
GROUP BY a.job_key;
