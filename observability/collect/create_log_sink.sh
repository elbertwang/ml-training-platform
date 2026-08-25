#!/bin/bash
# Selective Log Router sink: Cloud Logging -> BigQuery mlobs_raw.
#
# Why selective. Full-fidelity logs already live in the _Default bucket and are
# queryable through Log Analytics / the `defaultLink` linked dataset at no extra
# storage cost. What that surface is bad at is *repeated* querying: in
# tpu-for-training, touching the `labels` or `json_payload` columns costs ~303 GB
# and ~245 GB per day of data scanned, so an hourly model build would cost more
# than the rest of the platform combined. This sink pre-filters the ~0.2% of
# lines the model actually needs into small, cheap, permanently-retained tables.
#
# Deliberately NOT captured: severity=WARNING. In tpu-for-training it is 75% of
# all log volume (932M rows on 2026-08-24, almost entirely two gcsfuse-sidecar
# log storms) and carries no signal the ERROR tier does not already give us.
# Log *volume* anomalies are detected from the free log_entry_count metric
# instead -- see collect/metrics_exporter.py.
#
# This sink only decides what reaches BigQuery. It does not change Cloud Logging
# ingestion or the _Default bucket, so nothing that exists today stops working.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
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

DEST="bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET}"

if gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "  sink ${SINK_NAME}: updating"
  gcloud logging sinks update "$SINK_NAME" "$DEST" --project="$PROJECT_ID" \
    --log-filter="$FILTER" --use-partitioned-tables --quiet >/dev/null
else
  echo "  sink ${SINK_NAME}: creating"
  gcloud logging sinks create "$SINK_NAME" "$DEST" --project="$PROJECT_ID" \
    --log-filter="$FILTER" --use-partitioned-tables --quiet >/dev/null
fi

# The sink runs as a Google-managed writer identity. Grant it WRITER on this one
# dataset rather than a project-wide role.
WRITER=$(gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" \
         --format="value(writerIdentity)")
ACL=$(mktemp)
bq --project_id="$PROJECT_ID" show --format=prettyjson "${PROJECT_ID}:${DATASET}" > "$ACL"
if python3 - "$WRITER" "$ACL" <<'PY'
import json, sys
writer, path = sys.argv[1].replace("serviceAccount:", ""), sys.argv[2]
meta = json.load(open(path))
access = meta.setdefault("access", [])
if any(e.get("userByEmail") == writer for e in access):
    sys.exit(1)          # already granted; nothing to update
access.append({"role": "WRITER", "userByEmail": writer})
json.dump(meta, open(path, "w"))
PY
then
  bq --project_id="$PROJECT_ID" update --source "$ACL" "${PROJECT_ID}:${DATASET}" >/dev/null
  echo "  granted WRITER to ${WRITER}"
else
  echo "  writer identity already has WRITER"
fi
rm -f "$ACL"

echo "  note: a sink is not retroactive -- it exports only logs written from now on."
