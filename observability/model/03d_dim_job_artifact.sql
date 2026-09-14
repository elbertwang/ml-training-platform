-- dim_job_artifact: where a job wrote its TensorBoard, per job_key.
--
-- MaxText logs the composed path once per pod at startup:
--
--   INFO:maxtext.configs.pyconfig:Config param tensorboard_dir: gs://<base_output_directory>/<run_name>/tensorboard/
--
-- **Parsed, not reconstructed.** The rule really is
-- base_output_directory + "/" + run_name + "/tensorboard/" -- verified against
-- one pod carrying all three values -- but rebuilding it here would mean
-- collecting two more config lines and re-deriving a join MaxText already did.
-- It would also go quietly wrong the day MaxText changes the layout.
--
-- Neither component is derivable from anything else in the model. run_name is
-- not the jobset name: falcon-job-vhweixfuz5 runs
-- fused-moe-r196-pass-16l-fsdp128-state-capture. The bucket is not fixed
-- either -- tpu-for-training-falcon-logs for falcon, data_ant for the CI
-- pipeline -- so it cannot be templated from the project.
--
-- Grain is job_key, not pod. Every pod of a JobSet logs the same path, so 256
-- rows collapse to one. Where a job_key somehow carries two distinct paths the
-- most recent wins, which is the right answer for a restarted run that was
-- resubmitted against a new output directory.
--
-- Accumulate, never replace. A sink is not retroactive, so this table starts
-- when the filter clause was added (2026-09-09) and only grows; rebuilding it
-- from a window would drop every job that has since finished.
--
-- run_name is kept as its own column because it is the join key for the
-- workload-level goodput metrics (compute.googleapis.com/workload/*, keyed on
-- workload_id = run_name) and nothing else in the model records it.

CREATE TABLE IF NOT EXISTS mlobs_core.dim_job_artifact
(
  job_key        STRING NOT NULL,
  run_name       STRING,
  tensorboard_gs STRING,
  -- The same location as a console URL, so the dashboard can link rather than
  -- print a path the reader has to copy into a terminal. gs://b/p becomes
  -- https://console.cloud.google.com/storage/browser/b/p.
  tensorboard_url STRING,
  first_seen     TIMESTAMP,
  last_seen      TIMESTAMP
)
CLUSTER BY job_key;

MERGE mlobs_core.dim_job_artifact T
USING (
  WITH raw AS (
    SELECT
      p.job_key,
      l.timestamp,
      -- Trailing slash trimmed so the console URL does not end in an empty
      -- path segment, which renders as a folder that does not exist.
      REGEXP_REPLACE(
        REGEXP_EXTRACT(COALESCE(l.text_payload, JSON_VALUE(l.json_payload, '$.message')),
                       r'Config param tensorboard_dir:\s*(gs://\S+)'),
        r'/+$', '') AS tensorboard_gs
    FROM mlobs_core.v_sink_logs l
    JOIN mlobs_core.dim_pod p
      ON p.pod_name = JSON_VALUE(l.resource, '$.labels.pod_name')
    WHERE l.timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY)
      AND l.log_id IN ('stdout', 'stderr')
      AND COALESCE(l.text_payload, JSON_VALUE(l.json_payload, '$.message'))
          LIKE '%Config param tensorboard_dir%'
      AND p.job_key IS NOT NULL
    UNION ALL
    -- The same lines lifted out of Cloud Logging for the period before the sink
    -- clause existed; see collect/backfill_tensorboard_dir.sh. Unwindowed on
    -- purpose -- that is the whole point of it -- and empty until it has run.
    SELECT p.job_key, b.timestamp, REGEXP_REPLACE(b.tensorboard_gs, r'/+$', '')
    FROM mlobs_raw.tensorboard_dir_backfill b
    JOIN mlobs_core.dim_pod p ON p.pod_name = b.pod_name
    WHERE p.job_key IS NOT NULL
  )
  SELECT
    job_key,
    -- run_name is the last path segment before /tensorboard.
    REGEXP_EXTRACT(ANY_VALUE(tensorboard_gs), r'/([^/]+)/tensorboard$') AS run_name,
    ARRAY_AGG(tensorboard_gs ORDER BY timestamp DESC LIMIT 1)[OFFSET(0)] AS tensorboard_gs,
    MIN(timestamp) AS first_seen,
    MAX(timestamp) AS last_seen
  FROM raw
  WHERE tensorboard_gs IS NOT NULL
  GROUP BY job_key
) S
ON T.job_key = S.job_key
WHEN MATCHED THEN UPDATE SET
  run_name        = S.run_name,
  tensorboard_gs  = S.tensorboard_gs,
  tensorboard_url = CONCAT('https://console.cloud.google.com/storage/browser/',
                           SUBSTR(S.tensorboard_gs, 6)),
  -- LEAST/GREATEST for the same reason as dim_node_pool: the source is a
  -- three-hour window and taking its bounds directly would walk first_seen
  -- forward every refresh.
  first_seen      = LEAST(T.first_seen, S.first_seen),
  last_seen       = GREATEST(T.last_seen, S.last_seen)
WHEN NOT MATCHED THEN INSERT
  (job_key, run_name, tensorboard_gs, tensorboard_url, first_seen, last_seen)
VALUES
  (S.job_key, S.run_name, S.tensorboard_gs,
   CONCAT('https://console.cloud.google.com/storage/browser/', SUBSTR(S.tensorboard_gs, 6)),
   S.first_seen, S.last_seen);
