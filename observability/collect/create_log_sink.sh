#!/bin/bash
# Selective Log Router sink: Cloud Logging -> BigQuery mlobs_raw.
#
# Why selective. Full-fidelity logs already live in the _Default bucket and are
# queryable through Log Analytics / the `defaultLink` linked dataset at no extra
# storage cost. What that surface is bad at is *repeated* querying: touching the
# `labels` or `json_payload` columns costs ~300 GB and ~245 GB per day of data
# scanned respectively, so an hourly model build would cost more than the rest
# of the platform combined. This sink pre-filters the ~0.2% of lines the model
# actually needs into small, cheap, permanently-retained tables.
#
# Deliberately NOT captured: severity=WARNING. It is 75% of all log volume here
# (932M rows on 2026-08-24, almost all of it two gcsfuse-sidecar log storms) and
# carries no signal the ERROR tier does not already give us.
#
# This sink only decides what reaches BigQuery. It does not change Cloud Logging
# ingestion or the _Default bucket, so nothing that exists today stops working.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tpu-for-training}"
DATASET="${DATASET:-mlobs_raw}"
SINK_NAME="${SINK_NAME:-mlobs-selective}"

FILTER='
(
  jsonPayload.message:"completed step"
  OR textPayload:"completed step"
  OR severity>=ERROR
  OR log_id("events")
  OR log_id("container.googleapis.com/cluster-autoscaler-visibility")
  OR log_id("tpu.googleapis.com/runtime_monitor")
  OR log_id("ml_diagnostics_workload_event")
)
'

echo "=== Creating sink ${SINK_NAME} -> ${PROJECT_ID}:${DATASET} ==="
if gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud logging sinks update "$SINK_NAME" \
    "bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET}" \
    --project="$PROJECT_ID" \
    --log-filter="$FILTER" \
    --use-partitioned-tables
else
  gcloud logging sinks create "$SINK_NAME" \
    "bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET}" \
    --project="$PROJECT_ID" \
    --log-filter="$FILTER" \
    --use-partitioned-tables
fi

# The sink runs as a Google-managed writer identity. Grant it WRITER on the one
# dataset rather than a project-wide role.
WRITER=$(gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" \
         --format="value(writerIdentity)")
echo "=== Granting ${WRITER} dataEditor on ${DATASET} ==="
bq --project_id="$PROJECT_ID" show --format=prettyjson "${PROJECT_ID}:${DATASET}" \
  > /tmp/${DATASET}_acl.json
python3 - "$WRITER" <<'PY'
import json, sys
writer = sys.argv[1].replace("serviceAccount:", "")
path = "/tmp/mlobs_raw_acl.json"
meta = json.load(open(path))
access = meta.setdefault("access", [])
if not any(e.get("userByEmail") == writer for e in access):
    access.append({"role": "WRITER", "userByEmail": writer})
    json.dump(meta, open(path, "w"))
    print("added")
else:
    print("already present")
PY
bq --project_id="$PROJECT_ID" update --source /tmp/${DATASET}_acl.json "${PROJECT_ID}:${DATASET}"

echo
echo "Done. A sink is not retroactive -- it exports only logs written from now on."
gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" \
  --format="value(name,destination,filter)"
