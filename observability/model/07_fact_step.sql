-- fact_step: one row per (attempt, step), parsed from the training log line.
--
-- This is the table an ML engineer actually needs, and every field it holds is
-- already flowing into the sink -- no config flag, no cooperation from the
-- workload. A `completed step` line carries 23 fields, including the three
-- earliest signals that a run is going wrong: `nan_iters`, `skipped_iters` and
-- `grad_norm`. Nothing in the model read them until now.
--
-- Grain is (attempt_uid, step), NOT (pod, step). All 64 pods of a JobSet log
-- the same step, and the scalar fields are global -- data-parallel replicas
-- compute the same loss, lr and grad_norm -- so collapsing them is not lossy.
-- The per-device fields are the exception: `TFLOP/s/device` and `seconds` are
-- measured locally and genuinely differ across ranks (46 distinct TFLOPs values
-- were measured on a single step of a 64-pod job). Those keep their spread,
-- because the spread IS the straggler signal: one slow rank holds up everyone.
--
-- Reads v_sink_logs, never defaultLink -- see model/04_fact_event.sql for why
-- that distinction is worth ~$1,200/month.
--
-- MFU is deliberately NOT computed here. Its denominator,
-- `peak_tflops_per_device`, comes from a `Config param` line rather than the
-- step line, and folding a second parse into this one would make a missing
-- config silently produce a wrong ratio instead of a visible NULL.

DECLARE step_window_start TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY);
DECLARE step_window_end   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- `\b` before the name is what keeps `loss` from matching inside `lm_loss` or
-- `moe_z_loss`: `_` is a word character, so there is no boundary there. Same
-- trick separates `grad_norm` from `raw_grad_norm`.
--
-- The alternation accepts `nan` and `inf` on purpose. BigQuery casts both to
-- the IEEE values, so a diverged step arrives as NaN rather than NULL, and NULL
-- keeps its real meaning: the field was absent.
CREATE OR REPLACE FUNCTION mlobs_core.step_field(msg STRING, field STRING)
RETURNS FLOAT64 AS (
  SAFE_CAST(
    REGEXP_EXTRACT(
      msg,
      CONCAT(r'\b', field, r':\s*(-?(?:[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?|nan|inf))')
    ) AS FLOAT64)
);

CREATE TABLE IF NOT EXISTS mlobs_core.fact_step
(
  step_time        TIMESTAMP NOT NULL,
  job_key          STRING,
  attempt_uid      STRING,
  job_family       STRING,
  step             INT64 NOT NULL,
  -- stability
  nan_iters        FLOAT64,
  skipped_iters    FLOAT64,
  grad_norm        FLOAT64,
  raw_grad_norm    FLOAT64,
  loss             FLOAT64,
  lm_loss          FLOAT64,
  moe_lb_loss      FLOAT64,
  moe_z_loss       FLOAT64,
  mtp_loss         FLOAT64,
  num_zeros        FLOAT64,
  -- efficiency, aggregated across ranks
  step_seconds_min FLOAT64,
  step_seconds_p50 FLOAT64,
  step_seconds_max FLOAT64,
  straggler_ratio  FLOAT64,
  tflops_p50       FLOAT64,
  tflops_min       FLOAT64,
  tflops_max       FLOAT64,
  tokens_per_sec_device_p50 FLOAT64,
  -- context
  lr               FLOAT64,
  global_batch_size FLOAT64,
  total_weights    FLOAT64,
  ranks_reporting  INT64
)
PARTITION BY DATE(step_time)
CLUSTER BY job_key, step;

BEGIN TRANSACTION;

DELETE FROM mlobs_core.fact_step
WHERE step_time >= step_window_start AND step_time < step_window_end;

INSERT INTO mlobs_core.fact_step
WITH raw AS (
  SELECT
    l.timestamp,
    JSON_VALUE(l.resource, '$.labels.pod_name') AS pod_name,
    COALESCE(l.text_payload, JSON_VALUE(l.json_payload, '$.message')) AS msg
  FROM mlobs_core.v_sink_logs l
  WHERE l.timestamp >= step_window_start AND l.timestamp < step_window_end
    AND l.log_id IN ('stdout', 'stderr')
    AND COALESCE(l.text_payload, JSON_VALUE(l.json_payload, '$.message'))
        LIKE '%completed step%'
),
parsed AS (
  SELECT
    r.timestamp,
    p.job_key,
    p.attempt_uid,
    p.job_family,
    -- `completion_index` is what makes the collapse safe: it identifies the
    -- rank, so a pod that restarts and re-reports the same step is one rank,
    -- not two.
    p.completion_index,
    CAST(mlobs_core.step_field(r.msg, 'completed step') AS INT64) AS step,
    mlobs_core.step_field(r.msg, 'nan_iters')          AS nan_iters,
    mlobs_core.step_field(r.msg, 'skipped_iters')      AS skipped_iters,
    mlobs_core.step_field(r.msg, 'grad_norm')          AS grad_norm,
    mlobs_core.step_field(r.msg, 'raw_grad_norm')      AS raw_grad_norm,
    mlobs_core.step_field(r.msg, 'loss')               AS loss,
    mlobs_core.step_field(r.msg, 'lm_loss')            AS lm_loss,
    mlobs_core.step_field(r.msg, 'moe_lb_loss')        AS moe_lb_loss,
    mlobs_core.step_field(r.msg, 'moe_z_loss')         AS moe_z_loss,
    mlobs_core.step_field(r.msg, 'mtp_loss')           AS mtp_loss,
    mlobs_core.step_field(r.msg, 'num_zeros')          AS num_zeros,
    mlobs_core.step_field(r.msg, 'seconds')            AS step_seconds,
    mlobs_core.step_field(r.msg, 'TFLOP/s/device')     AS tflops,
    mlobs_core.step_field(r.msg, 'Tokens/s/device')    AS tokens_per_sec_device,
    mlobs_core.step_field(r.msg, 'lr')                 AS lr,
    mlobs_core.step_field(r.msg, 'global_batch_size')  AS global_batch_size,
    mlobs_core.step_field(r.msg, 'total_weights')      AS total_weights
  FROM raw r
  JOIN mlobs_core.dim_pod p ON p.pod_name = r.pod_name
  WHERE p.attempt_uid IS NOT NULL
)
SELECT
  MIN(timestamp) AS step_time,
  job_key,
  attempt_uid,
  ANY_VALUE(job_family) AS job_family,
  step,
  -- Global scalars: MAX, not ANY_VALUE. Ranks agree on these, but a rank whose
  -- line was truncated contributes NULL, and ANY_VALUE may return that NULL --
  -- the same trap that produced empty job labels in dim_pod.
  MAX(nan_iters)     AS nan_iters,
  MAX(skipped_iters) AS skipped_iters,
  MAX(grad_norm)     AS grad_norm,
  MAX(raw_grad_norm) AS raw_grad_norm,
  MAX(loss)          AS loss,
  MAX(lm_loss)       AS lm_loss,
  MAX(moe_lb_loss)   AS moe_lb_loss,
  MAX(moe_z_loss)    AS moe_z_loss,
  MAX(mtp_loss)      AS mtp_loss,
  MAX(num_zeros)     AS num_zeros,
  -- Per-rank measurements: keep the distribution.
  MIN(step_seconds)                            AS step_seconds_min,
  APPROX_QUANTILES(step_seconds, 2)[OFFSET(1)] AS step_seconds_p50,
  MAX(step_seconds)                            AS step_seconds_max,
  -- The straggler signal, measured on the SLOW side only: how much longer the
  -- slowest rank took than the median. 1.0 is lockstep; 1.1 means someone is
  -- holding the collective up by 10%.
  --
  -- A symmetric spread would be wrong here, and measurably so. On step 7 of
  -- falcon-job-7v57lgnxq1, 63 ranks reported 56.047s and rank 24 reported
  -- 0.046s -- a rank that did not do the work at all. A (max-min)/max measure
  -- reads 0.999 there and calls it a catastrophic straggler, when the slow side
  -- was perfectly in lockstep. max/p50 correctly reads 1.0.
  --
  -- That fast outlier is itself a real signal, which is why step_seconds_min is
  -- kept: a rank finishing in milliseconds is skipping work, not winning.
  SAFE_DIVIDE(MAX(step_seconds),
              APPROX_QUANTILES(step_seconds, 2)[OFFSET(1)]) AS straggler_ratio,
  APPROX_QUANTILES(tflops, 2)[OFFSET(1)]       AS tflops_p50,
  MIN(tflops)                                  AS tflops_min,
  MAX(tflops)                                  AS tflops_max,
  APPROX_QUANTILES(tokens_per_sec_device, 2)[OFFSET(1)] AS tokens_per_sec_device_p50,
  MAX(lr)                AS lr,
  MAX(global_batch_size) AS global_batch_size,
  MAX(total_weights)     AS total_weights,
  COUNT(DISTINCT COALESCE(completion_index, -1)) AS ranks_reporting
FROM parsed
WHERE step IS NOT NULL
GROUP BY job_key, attempt_uid, step;

COMMIT TRANSACTION;
