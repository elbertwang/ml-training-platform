#!/usr/bin/env python3
"""Snapshot node pool -> node-name mapping into mlobs_raw.node_pool_snapshot.

Why this exists at all: a GKE node is named `gke-<cluster>-<8 hex>-<4 hex>`,
where the middle group identifies the *managed instance group*, not the pool.
Nothing in the node name, in dim_pod, or in any log we collect carries the pool
name. But a maintenance event names the pool and nothing else -- so without this
mapping there is no way to say which job an upgrade is about to interrupt.

The pool's instance groups are named `gke-<cluster>-<pool>-<8 hex>-grp` with the
same hex, so one nodePools.list call resolves it.

**Accumulate, never replace.** Measured against production: of 200 distinct node
names in dim_pod, only 47 resolve against a current nodePools.list -- the other
153 belong to falcon's ephemeral pools, which are created and deleted within a
job's lifetime and are simply gone by the time anyone asks. A snapshot that
overwrites would answer "unknown pool" for most of the fleet's history. So each
run appends what it can see and the model MERGEs, which is the same lesson as
dim_pod's TBD-2, learned here before it cost anything.

  node_pool_snapshot.py --project tpu-for-training --cluster tpu-training-antgroup
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

DEFAULT_PROJECT = os.environ.get("MLOBS_PROJECT", "tpu-for-training")
DEFAULT_DATASET = os.environ.get("MLOBS_RAW_DATASET", "mlobs_raw")
DEFAULT_CLUSTER = os.environ.get("GKE_CLUSTER", "")   # empty = discover
# "-" is the API's wildcard for every location. See fetch_clusters().
DEFAULT_LOCATION = os.environ.get("GKE_LOCATION", "-")

# gke-tpu-for-trainin-tpu-256chips-p-aad6ce9c-grp -> aad6ce9c
IG_HASH = re.compile(r"-([0-9a-f]{8})-grp$")


def access_token() -> str:
    env = os.environ.get("CLOUDSDK_AUTH_ACCESS_TOKEN")
    if env:
        return env
    return subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def fetch_clusters(token, project, location):
    """Every cluster, as (name, location) pairs.

    Discovered rather than configured. The project went from one cluster to
    three without this collector noticing, and a finance number that silently
    covers a subset of the fleet is worse than one that is missing.

    The location defaults to "-", meaning every region, and each cluster's own
    location travels back with it -- listing is region-wide but nodePools.list
    is not, so a single location variable could only ever be right for one of
    them. With a hard-coded us-central1 the collector had missed
    gke-tpu-train-us-east1-1-prod for the four days it had existed, while
    metrics_exporter -- which filters on metric and resource type, never on
    location -- was already landing everything that cluster produced. CPU-only
    today, so the damage is zero; the first TPU pool there would have appeared
    in every metric and in no capacity table.
    """
    url = (f"https://container.googleapis.com/v1/projects/{project}"
           f"/locations/{location}/clusters")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        body = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        sys.exit(f"clusters.list failed: HTTP {e.code} {e.read()[:300]}")
    return [(c["name"], c.get("location", location))
            for c in body.get("clusters", [])]


def fetch_pools(token, project, location, cluster):
    url = (f"https://container.googleapis.com/v1/projects/{project}"
           f"/locations/{location}/clusters/{cluster}/nodePools")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=120)).get("nodePools", [])
    except urllib.error.HTTPError as e:
        sys.exit(f"nodePools.list failed: HTTP {e.code} {e.read()[:300]}")


def to_rows(pools, cluster, location, observed_at):
    """One row per (pool, instance-group hash). A pool spans several groups when
    it is regional, and each group contributes its own hash to node names."""
    rows = []
    for p in pools:
        for url in p.get("instanceGroupUrls", []):
            m = IG_HASH.search(url.rsplit("/", 1)[-1])
            if not m:
                continue
            cfg = p.get("config", {})
            # Which pot of money this pool draws on. Finance counts reserved
            # capacity only, so this is what keeps an on-demand or flex-start
            # job out of a ratio whose denominator is the reservation -- without
            # it the numerator can exceed the denominator and the ratio goes
            # over 100%.
            #   SPECIFIC_RESERVATION  consumes a named reservation
            #   NO_RESERVATION        on-demand, or flex-start
            #   NONE / absent         no affinity expressed; treated as on-demand
            ra = cfg.get("reservationAffinity") or {}
            affinity = ra.get("consumeReservationType") or "NONE"
            # values[0] is either a bare reservation name or a full path down to
            # a reservation sub-block; the reservation is the first segment
            # after /reservations/, and both spellings occur in this cluster.
            target = (ra.get("values") or [""])[0]
            if "/reservations/" in target:
                target = target.split("/reservations/", 1)[1].split("/", 1)[0]
            rows.append({
                "cluster_name": cluster,
                "location": location,
                "node_pool": p["name"],
                "ig_hash": m.group(1),
                "reservation_affinity": affinity,
                "reservation_name": target or None,
                "capacity_class": ("reserved" if affinity == "SPECIFIC_RESERVATION"
                                   else "spot" if cfg.get("spot")
                                   else "flex" if "flex" in p["name"]
                                   else "on_demand"),
                "machine_type": cfg.get("machineType"),
                "tpu_topology": (p.get("placementPolicy", {}).get("tpuTopology")
                                 or cfg.get("placementPolicy", {}).get("tpuTopology")),
                "node_version": p.get("version"),
                "initial_node_count": p.get("initialNodeCount"),
                "pool_status": p.get("status"),
                "observed_at": observed_at,
            })
    return rows


def bq_load_rows(project, dataset, table, rows, schema, clustering=None):
    """Load NDJSON into one table. Shared by both snapshots in this collector."""
    if not rows:
        print(f"  {table}: nothing to load", flush=True)
        return
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        for r in rows:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")
        path = fh.name
    cmd = [
        "bq", f"--project_id={project}", "load",
        "--source_format=NEWLINE_DELIMITED_JSON",
        "--time_partitioning_field=observed_at",
    ]
    if clustering:
        cmd.append(f"--clustering_fields={clustering}")
    cmd += [f"{dataset}.{table}", path, schema]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        # bq writes load errors to stdout, not stderr -- print both or the
        # failure reads as empty. Learned from metric_samples' schema drift.
        sys.exit(f"load into {table} failed:\n{res.stdout}\n{res.stderr}")
    print(f"  {table}: loaded {len(rows)} rows", flush=True)


def bq_load(project, dataset, rows):
    bq_load_rows(
        project, dataset, "node_pool_snapshot", rows,
        ("cluster_name:STRING,location:STRING,node_pool:STRING,ig_hash:STRING,"
         "reservation_affinity:STRING,reservation_name:STRING,capacity_class:STRING,"
         "machine_type:STRING,tpu_topology:STRING,node_version:STRING,"
         "initial_node_count:INTEGER,pool_status:STRING,observed_at:TIMESTAMP"),
        clustering="node_pool")


def fetch_reservations(token, project):
    """id, name and size for every reservation, from the Compute API.

    The reason this exists is a mismatch between two sources that both describe
    the same reservation and share no key:

        compute.googleapis.com/reservation/reserved   resource label
                                                      reservation_id=2877059003882016695
        container nodePools[].config.reservationAffinity
                                                      values=[ghostfish-luwqsqv4va7tk]

    The metric carries only the numeric id, the node pool only the name, so the
    denominator (chips paid for) and the numerator (chips doing work) cannot be
    joined without this. The Compute API returns both in one call, which is why
    the mapping is resolved at collection time and written into the capacity
    table rather than published as a bridge for the consumer to join -- they get
    one denominator table carrying both identifiers.

    Folded into this collector rather than given its own Cloud Run job: it needs
    the same token, runs on the same cadence, and returns two rows.
    """
    url = (f"https://compute.googleapis.com/compute/v1/projects/{project}"
           f"/aggregated/reservations")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        body = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        # Raised, not swallowed. This returned [] for three days on a 403 --
        # the caller's `if res:` then wrote nothing, printed nothing, and the
        # job exited 0 on every one of 160 runs. reservation_snapshot stopped
        # at two rows from 2026-09-11 06:12 and mlobs_share.v_capacity_daily
        # lost the name for five of its seven reservations, which is a column
        # the customer document calls the join key. A collector that cannot
        # collect has to say so; refresh.sh decides whether that is fatal.
        raise RuntimeError(
            f"reservations.aggregatedList: HTTP {e.code} {e.read()[:300]}"
        ) from None
    rows = []
    for scope, blk in (body.get("items") or {}).items():
        for r in blk.get("reservations", []):
            # TPU pod slices come back as aggregateReservation, not
            # specificReservation -- the shape a first version assumed, which
            # left every count NULL. The accelerator count is the chip count,
            # and the API reports reserved and in-use side by side:
            #
            #   aggregateReservation.reservedResources[].accelerator.acceleratorCount
            #   aggregateReservation.inUseResources[].accelerator.acceleratorCount
            #
            # That makes this an independent check on
            # compute.googleapis.com/reservation/{reserved,used}: two unrelated
            # surfaces reporting the same pair. specificReservation is still
            # handled because a non-TPU reservation would use it.
            def _chips(bucket):
                total = 0
                for item in (agg.get(bucket) or []):
                    total += int(item.get("accelerator", {}).get("acceleratorCount") or 0)
                return total or None

            agg = r.get("aggregateReservation", {}) or {}
            accel_type = None
            for item in (agg.get("reservedResources") or []):
                accel_type = item.get("accelerator", {}).get("acceleratorType")
                if accel_type:
                    accel_type = accel_type.rsplit("/", 1)[-1]
                    break
            reserved = _chips("reservedResources")
            in_use = _chips("inUseResources")
            if reserved is None:
                sp = r.get("specificReservation", {}) or {}
                reserved = int(sp["count"]) if sp.get("count") else None
            rows.append({
                "reservation_id": r.get("id"),
                "reservation_name": r.get("name"),
                "zone": scope.split("/")[-1],
                "status": r.get("status"),
                "vm_family": agg.get("vmFamily"),
                "accelerator_type": accel_type,
                "reserved_chips": reserved,
                "in_use_chips": in_use,
                "observed_at": None,   # filled by the caller
            })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=DEFAULT_PROJECT)
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--cluster", default=DEFAULT_CLUSTER,
                    help="comma-separated; empty discovers every cluster "
                         "in the location")
    ap.add_argument("--location", default=DEFAULT_LOCATION)
    ap.add_argument("--print", dest="print_only", action="store_true",
                    help="write the rows to stdout as NDJSON instead of loading "
                         "them, to see what a run would record")
    a = ap.parse_args()

    # Printed by every entry point, because the image is built from a working
    # directory and the tag alone cannot say what is in it. See the build-stamp
    # note in schedule/deploy.sh.
    print(f"  build={os.environ.get('BUILD_STAMP', 'unstamped')}", flush=True)
    token = access_token()
    observed_at = dt.datetime.now(dt.timezone.utc).isoformat()
    # An explicit --cluster keeps --location's meaning: you named the cluster,
    # so you have to say where it is.
    clusters = ([(c.strip(), a.location) for c in a.cluster.split(",") if c.strip()]
                or fetch_clusters(token, a.project, a.location))
    rows = []
    for cluster, cluster_location in clusters:
        pools = fetch_pools(token, a.project, cluster_location, cluster)
        got = to_rows(pools, cluster, cluster_location, observed_at)
        rows.extend(got)
        if not a.print_only:
            print(f"  {cluster}: {len(pools)} pools -> {len(got)} instance groups",
                  flush=True)
    if a.print_only:
        for r in rows:
            print(json.dumps(r, ensure_ascii=False))
        return
    bq_load(a.project, a.dataset, rows)

    # Reservations, into their own table. Same run, same token, two rows.
    # This is the only source of reservation_id -> reservation_name: the
    # Monitoring series carries the numeric id and nothing else, so without
    # this call v_capacity_daily can only publish ids.
    res = fetch_reservations(token, a.project)
    for r in res:
        r["observed_at"] = observed_at
    if not res:
        # An empty list is a real answer only if the project has no
        # reservations, which would itself be worth seeing in the log.
        print("  reservation_snapshot: no reservations returned", flush=True)
    else:
        bq_load_rows(
            a.project, a.dataset, "reservation_snapshot", res,
            "reservation_id:STRING,reservation_name:STRING,zone:STRING,"
            "status:STRING,vm_family:STRING,accelerator_type:STRING,"
            "reserved_chips:INTEGER,in_use_chips:INTEGER,observed_at:TIMESTAMP")


if __name__ == "__main__":
    main()
