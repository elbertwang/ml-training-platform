#!/usr/bin/env python3
"""Rebuild node pool history from Cloud Asset Inventory.

    python3 collect/backfill_node_pools_asset.py --project tpu-for-training --days 31

node_pool_snapshot.py reads the live GKE API, so it can only ever record pools
that exist when it runs. falcon creates and deletes a node pool inside a single
job, which means every pool older than the collector is gone -- and with it the
capacity class of the work that ran there. Measured 2026-09-04: 1,378 distinct
instance groups appear in dim_pod over 31 days and dim_node_pool knew 58.

That gap suppressed chip_utilization and MFU for every day before 2026-09-01,
because fin_daily gates them on work_coverage and work_coverage was 0.09-0.90.

**Cloud Asset Inventory keeps 35 days of configuration history**, and one call
returns everything the mapping needs:

    config.reservationAffinity   the capacity class, with the reservation name
    instanceGroupUrls            the 8-hex group id that node names carry
    readTime                     any point in time inside the retention window

Three routes were tried and failed before this one, all for the same reason --
they looked for the answer at the wrong layer:

  * node names. The short form is `gke-tpu-3cf4ffd9-w09c`, which carries the
    group hash and no pool name at all, so the pool is simply not in there.
  * compute.instances.insert audit logs. Their request body holds only `@type`:
    GKE creates nodes through an instance group manager, so no per-instance
    record of reservationAffinity is ever written.
  * instanceGroupManagers audit entries. These do name pool and hash together,
    but a spot check found 1 of 5 missing hashes -- not a basis for a rebuild.

reservationAffinity is a property of the node pool, not of the node, so no
node-level channel was ever going to carry it.

Rows go into mlobs_raw.node_pool_snapshot -- the same table the live collector
writes, through the same to_rows() -- with observed_at set to the snapshot's
readTime. Nothing downstream needs to know a row came from here, and the
capacity-class rule cannot drift between the two sources because there is only
one copy of it.

Afterwards, run 03b_dim_node_pool.sql with its MERGE window widened past the
oldest snapshot, or the two-day default will ignore everything written here:

    sed 's/INTERVAL 2 DAY/INTERVAL 40 DAY/' model/03b_dim_node_pool.sql \\
      | bq --project_id=<project> query --use_legacy_sql=false

DAILY snapshots, which is a deliberate limit. A pool that is created and deleted
between two readTimes is invisible: 906 of the 1,378 hashes stay unresolved for
exactly that reason. They cost nothing today because dim_pod marks those pods
job_family='falcon' and fin_work_daily already treats falcon as reserved. If
that assumption is ever dropped, this needs an hourly cadence -- 24x the calls,
still free.

One-off by nature. Asset Inventory's window is 35 days and it only rolls
forward, so history not captured now is unrecoverable; going forward the
five-minute mlobs-poolsnap job keeps the table current on its own.
"""
import argparse
import datetime as dt
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

from node_pool_snapshot import access_token, bq_load, to_rows

ASSET_TYPE = "container.googleapis.com/NodePool"


def fetch_assets(token, project, read_time):
    """Every NodePool that existed at read_time, following pagination.

    X-Goog-User-Project is required and its absence is not obvious from the
    error: application default credentials bill quota to the ADC client project
    rather than to this one, so the call fails with SERVICE_DISABLED naming a
    project number nobody recognises.
    """
    assets, page = [], None
    while True:
        params = {
            "assetTypes": ASSET_TYPE,
            "contentType": "RESOURCE",
            "pageSize": "500",
            "readTime": read_time,
        }
        if page:
            params["pageToken"] = page
        url = (f"https://cloudasset.googleapis.com/v1/projects/{project}/assets"
               f"?{urllib.parse.urlencode(params)}")
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "X-Goog-User-Project": project,
        })
        try:
            body = json.load(urllib.request.urlopen(req, timeout=180))
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"listAssets at {read_time}: HTTP {e.code} {e.read()[:300]}") from None
        assets.extend(body.get("assets", []))
        page = body.get("nextPageToken")
        if not page:
            return assets


def split_asset(asset):
    """(cluster, location, pool-resource) out of one asset.

    asset.name is
      //container.googleapis.com/projects/P/locations/L/clusters/C/nodePools/N
    and the GKE API shape is preserved underneath `resource.data`, which is why
    to_rows() can be reused verbatim rather than reimplemented against a second
    spelling of the same object.
    """
    parts = asset.get("name", "").split("/")
    try:
        location = parts[parts.index("locations") + 1]
        cluster = parts[parts.index("clusters") + 1]
    except (ValueError, IndexError):
        return None
    data = asset.get("resource", {}).get("data")
    if not data:
        return None
    return cluster, location, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--dataset", default="mlobs_raw")
    ap.add_argument("--days", type=int, default=31,
                    help="how many daily snapshots back to take; Asset "
                         "Inventory retains 35")
    ap.add_argument("--print", dest="dry", action="store_true",
                    help="report what each snapshot holds and load nothing")
    args = ap.parse_args()

    if args.days > 35:
        print(f"  --days {args.days} exceeds Asset Inventory's 35-day window; "
              f"snapshots past it return empty", file=sys.stderr)

    token = access_token()
    rows, seen_hashes = [], set()
    now = dt.datetime.now(dt.timezone.utc)

    for back in range(args.days + 1):
        stamp = now - dt.timedelta(days=back)
        read_time = stamp.strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            assets = fetch_assets(token, args.project, read_time)
        except RuntimeError as e:
            # One unreadable day must not discard the other thirty. The window
            # edge in particular returns errors rather than an empty list.
            print(f"  {read_time}: {e}", flush=True)
            continue

        day_rows = []
        for asset in assets:
            got = split_asset(asset)
            if not got:
                continue
            cluster, location, data = got
            # observed_at is the readTime, not now: these rows describe the
            # fleet as it was, and dim_node_pool derives first_seen/last_seen
            # from them.
            day_rows.extend(to_rows([data], cluster, location, read_time))

        fresh = {r["ig_hash"] for r in day_rows} - seen_hashes
        seen_hashes |= {r["ig_hash"] for r in day_rows}
        rows.extend(day_rows)
        print(f"  {read_time[:10]}: {len(assets)} pools, {len(day_rows)} groups, "
              f"{len(fresh)} new", flush=True)

    classes = {}
    for r in rows:
        classes[r["capacity_class"]] = classes.get(r["capacity_class"], 0) + 1
    print(f"  {len(rows)} rows, {len(seen_hashes)} distinct instance groups, "
          f"by capacity class: {classes}")

    if args.dry:
        print("  --print given, nothing loaded")
        return
    bq_load(args.project, args.dataset, rows)
    print("  done. Now run 03b_dim_node_pool.sql with a widened MERGE window "
          "or these rows will be ignored:")
    print("    sed 's/INTERVAL 2 DAY/INTERVAL 40 DAY/' model/03b_dim_node_pool.sql \\")
    print(f"      | bq --project_id={args.project} query --use_legacy_sql=false")


if __name__ == "__main__":
    main()
