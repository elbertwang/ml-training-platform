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
DEFAULT_LOCATION = os.environ.get("GKE_LOCATION", "us-central1")

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
    """Every cluster in the location.

    Discovered rather than configured. The project went from one cluster to
    three without this collector noticing, and a finance number that silently
    covers a subset of the fleet is worse than one that is missing.
    """
    url = (f"https://container.googleapis.com/v1/projects/{project}"
           f"/locations/{location}/clusters")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        body = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        sys.exit(f"clusters.list failed: HTTP {e.code} {e.read()[:300]}")
    return [c["name"] for c in body.get("clusters", [])]


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


def bq_load(project, dataset, rows):
    if not rows:
        print("  nothing to load", flush=True)
        return
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        for r in rows:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")
        path = fh.name
    cmd = [
        "bq", f"--project_id={project}", "load",
        "--source_format=NEWLINE_DELIMITED_JSON",
        "--time_partitioning_field=observed_at",
        "--clustering_fields=node_pool",
        f"{dataset}.node_pool_snapshot", path,
        ("cluster_name:STRING,location:STRING,node_pool:STRING,ig_hash:STRING,"
         "reservation_affinity:STRING,reservation_name:STRING,capacity_class:STRING,"
         "machine_type:STRING,tpu_topology:STRING,node_version:STRING,"
         "initial_node_count:INTEGER,pool_status:STRING,observed_at:TIMESTAMP"),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        # bq writes load errors to stdout, not stderr -- print both or the
        # failure reads as empty. Learned from metric_samples' schema drift.
        sys.exit(f"load failed:\n{res.stdout}\n{res.stderr}")
    print(f"  loaded {len(rows)} rows", flush=True)


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

    token = access_token()
    observed_at = dt.datetime.now(dt.timezone.utc).isoformat()
    clusters = ([c.strip() for c in a.cluster.split(",") if c.strip()]
                or fetch_clusters(token, a.project, a.location))
    rows = []
    for cluster in clusters:
        pools = fetch_pools(token, a.project, a.location, cluster)
        got = to_rows(pools, cluster, a.location, observed_at)
        rows.extend(got)
        if not a.print_only:
            print(f"  {cluster}: {len(pools)} pools -> {len(got)} instance groups",
                  flush=True)
    if a.print_only:
        for r in rows:
            print(json.dumps(r, ensure_ascii=False))
        return
    bq_load(a.project, a.dataset, rows)


if __name__ == "__main__":
    main()
