-- jobs_on_target: which jobs were running on a node, or on a node pool, during
-- a window. The single definition of infrastructure-event attribution.
--
-- It exists as a table function rather than as a snippet because two callers
-- need the same answer at different times: fact_incident computes it in batch
-- for history, and the notifier calls it at delivery time to say who an upgrade
-- is about to interrupt. The same rule written twice in two places is how the
-- goodput derivation drifted twice in one week; once is the fix.
--
-- Node pool resolution goes through the instance-group hash, because a GKE node
-- name does not contain its pool. See model/03b_dim_node_pool.sql. Nodes whose
-- pool has since been deleted -- three quarters of them, all falcon's ephemeral
-- pools -- resolve only for events recorded while the pool still existed, which
-- is the best any mapping can do and is why dim_node_pool accumulates.
--
-- The window is inclusive of overlap, not containment: a pod counts if its
-- observed life intersects the window at all. An upgrade that drains a node
-- stops the pod's logs, so requiring containment would exclude exactly the pods
-- the event affected.
CREATE OR REPLACE TABLE FUNCTION mlobs_core.jobs_on_target(
  p_target_kind STRING,   -- 'node' or 'node_pool'
  p_target      STRING,
  p_from        TIMESTAMP,
  p_to          TIMESTAMP
) AS
SELECT
  p.job_key,
  ANY_VALUE(p.namespace_name)              AS namespace_name,
  ANY_VALUE(p.job_family)                  AS job_family,
  COUNT(DISTINCT p.pod_name)               AS pods,
  COUNT(DISTINCT p.node_name)              AS nodes,
  MIN(p.first_seen)                        AS first_seen,
  MAX(p.last_seen)                         AS last_seen
FROM mlobs_core.dim_pod p
LEFT JOIN mlobs_core.dim_node_pool np
  ON np.ig_hash = mlobs_core.node_ig_hash(p.node_name)
WHERE p.node_name IS NOT NULL
  AND p.last_seen  >= p_from
  AND p.first_seen <= p_to
  AND CASE p_target_kind
        WHEN 'node'      THEN p.node_name    = p_target
        WHEN 'node_pool' THEN np.node_pool   = p_target
        ELSE FALSE
      END
GROUP BY p.job_key;
