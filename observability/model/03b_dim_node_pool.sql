-- dim_node_pool: which node pool a node belongs to.
--
-- Nothing in a log says this. A maintenance event names a node pool and nothing
-- else; every other channel names a node or a pod. Without the mapping there is
-- no way to answer the only question that matters when an upgrade starts --
-- which job is running on the pool about to be drained.
--
-- The bridge between the two is the instance group. A pool's groups are named
-- `gke-<cluster>-<pool>-<8 hex>-grp`, and its nodes are named
-- `gke-<...>-<same 8 hex>-<suffix>`, so the hex identifies the group in both.
-- Two node naming lengths exist in this cluster --
--   gke-tpu-aad6ce9c-kt79
--   gke-tpu-training-antg-cpu-compile-c3d-c2597058-qbnx
-- -- and anchoring on the trailing suffix resolves both with one rule.
--
-- **Accumulate, never replace.** Measured before building this: of 200 distinct
-- node names in dim_pod only 47 resolve against a live nodePools.list, because
-- falcon creates and deletes a pool inside one job's lifetime. A table rebuilt
-- from the current snapshot would answer "unknown" for three quarters of the
-- fleet's history, and would answer it worse every month. Rows are kept
-- forever: 60 per snapshot, a few hundred distinct groups a year, kilobytes.

CREATE OR REPLACE FUNCTION mlobs_core.node_ig_hash(node_name STRING)
RETURNS STRING AS (
  -- Defined once and used by every consumer. The same expression inlined in two
  -- places is how the goodput derivation drifted twice in one week.
  REGEXP_EXTRACT(node_name, r'-([0-9a-f]{8})-[a-z0-9]{3,6}$')
);

CREATE TABLE IF NOT EXISTS mlobs_core.dim_node_pool
(
  cluster_name   STRING,
  location       STRING,
  node_pool      STRING,
  ig_hash        STRING,
  -- Which pot of money the pool draws on: reserved / on_demand / flex / spot.
  -- Finance counts reserved only, and this is what keeps flex-start work out
  -- of a numerator whose denominator is the reservation.
  reservation_affinity STRING,
  reservation_name     STRING,
  capacity_class       STRING,
  machine_type   STRING,
  tpu_topology   STRING,
  node_version   STRING,
  pool_status    STRING,
  -- When this instance group was first and last seen alive. An ephemeral pool
  -- that no longer exists keeps its window, which is what makes attribution of
  -- an old event possible at all.
  first_seen     TIMESTAMP,
  last_seen      TIMESTAMP
)
CLUSTER BY ig_hash;

-- Two days of snapshots is far more overlap than a 30-minute cadence needs; it
-- costs nothing on a table this size and absorbs a refresh outage without
-- leaving a hole.
MERGE mlobs_core.dim_node_pool T
USING (
  SELECT
    cluster_name,
    ig_hash,
    ANY_VALUE(location)      AS location,
    ANY_VALUE(node_pool)     AS node_pool,
    ANY_VALUE(reservation_affinity) AS reservation_affinity,
    ANY_VALUE(reservation_name)     AS reservation_name,
    ANY_VALUE(capacity_class)       AS capacity_class,
    ANY_VALUE(machine_type)  AS machine_type,
    ANY_VALUE(tpu_topology)  AS tpu_topology,
    -- version and status change over the pool's life; keep the newest
    ARRAY_AGG(node_version ORDER BY observed_at DESC LIMIT 1)[OFFSET(0)] AS node_version,
    ARRAY_AGG(pool_status  ORDER BY observed_at DESC LIMIT 1)[OFFSET(0)] AS pool_status,
    MIN(observed_at) AS first_seen,
    MAX(observed_at) AS last_seen
  FROM mlobs_raw.node_pool_snapshot
  WHERE observed_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
  GROUP BY cluster_name, ig_hash
) S
ON T.cluster_name = S.cluster_name AND T.ig_hash = S.ig_hash
WHEN MATCHED THEN UPDATE SET
  -- LEAST/GREATEST, not S.first_seen/S.last_seen: the source is a two-day
  -- window, so taking its bounds directly would walk the recorded lifetime
  -- forward and silently erase when a pool actually appeared.
  first_seen   = LEAST(T.first_seen, S.first_seen),
  last_seen    = GREATEST(T.last_seen, S.last_seen),
  node_pool    = S.node_pool,
  location     = S.location,
  reservation_affinity = S.reservation_affinity,
  reservation_name = S.reservation_name,
  capacity_class = S.capacity_class,
  machine_type = S.machine_type,
  tpu_topology = S.tpu_topology,
  node_version = S.node_version,
  pool_status  = S.pool_status
WHEN NOT MATCHED THEN INSERT
  (cluster_name, location, node_pool, ig_hash, reservation_affinity,
   reservation_name, capacity_class, machine_type, tpu_topology,
   node_version, pool_status, first_seen, last_seen)
VALUES
  (S.cluster_name, S.location, S.node_pool, S.ig_hash, S.reservation_affinity,
   S.reservation_name, S.capacity_class, S.machine_type,
   S.tpu_topology, S.node_version, S.pool_status, S.first_seen, S.last_seen);
