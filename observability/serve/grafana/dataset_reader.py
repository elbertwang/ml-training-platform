#!/usr/bin/env python3
"""Add a service account as READER on a BigQuery dataset, and verify nothing else moved.

Called twice by deploy.sh, around the `bq update`:

  --mode=patch   read `bq show` output, emit the minimal update body
  --mode=verify  read `bq show` output on stdin, exit non-zero if any
                 pre-existing access entry vanished or ours did not land

Why not `bq get-iam-policy` / `set-iam-policy`: those need an allowlist that
tpu-for-training does not have. The dataset resource's `access` array is the
supported route, and its READER role is exactly roles/bigquery.dataViewer.

Why the verify step: `bq update --source` replaces the dataset configuration
wholesale rather than merging. A mistake in the patch body would silently drop
other principals' grants on a customer's production dataset, and nothing in the
command output would say so.
"""

import argparse
import json
import sys


def entry_key(a):
    """Identify an access entry regardless of which principal field it uses."""
    who = (a.get("userByEmail") or a.get("groupByEmail") or a.get("specialGroup")
           or a.get("iamMember") or a.get("domain"))
    if who is None:
        # views/routines/datasets grants carry a nested object instead
        who = json.dumps(a, sort_keys=True)
    return (a.get("role"), who)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("patch", "verify"), required=True)
    ap.add_argument("--before", required=True, help="`bq show` output from before the update")
    ap.add_argument("--out", help="where to write the update body (patch mode)")
    ap.add_argument("--sa", required=True)
    args = ap.parse_args()

    before = json.load(open(args.before)).get("access", [])
    want = ("READER", args.sa)

    if args.mode == "patch":
        access = list(before)
        if want not in {entry_key(a) for a in access}:
            access.append({"role": "READER", "userByEmail": args.sa})
        # Only the mutable field. Passing the whole `bq show` payload back makes
        # bq reject output-only members such as etag, id and selfLink.
        json.dump({"access": access}, open(args.out, "w"))
        return

    after = json.load(sys.stdin).get("access", [])
    lost = {entry_key(a) for a in before} - {entry_key(a) for a in after}
    if lost:
        sys.exit(f"ABORT: dataset access entries disappeared: {sorted(lost)}")
    if want not in {entry_key(a) for a in after}:
        sys.exit("ABORT: the READER grant did not take effect")


if __name__ == "__main__":
    main()
