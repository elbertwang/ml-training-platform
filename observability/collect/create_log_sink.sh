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

# The last three are the infrastructure side of the timeline: things GKE did to
# the cluster, as opposed to things the training process said. They replace a
# Cloud Scheduler job that polled the GKE Operations API every minute, and the
# replacement was measured rather than assumed:
#
#   coverage  Each GKE operation type was matched against the log by hand, not
#             assumed. UPGRADE_NODES: 8/8 have one maintenance RUNNING event on
#             the same node pool. CREATE_NODE_POOL 14:14 and DELETE_NODE_POOL
#             11:11 on a sampled day, paired through operation.first/last.
#             AUTO_REPAIR_NODES appears as the audit method
#             ClusterManagerInternal.RepairNodePool -- the whole operation ID is
#             searchable in the log, which is how the pairing was confirmed.
#   history   The Operations API retains about 13 days, Cloud Logging 30. Over
#             the same 30 days the log holds 7 auto-repairs while the API can
#             still show 1, so switching to logs lengthens the record rather
#             than shortening it.
#   layers    AUTO_REPAIR_NODES (node pool, GKE-initiated, ~7/month) and
#             compute.instances.repair.recreateInstance (single VM, MIG
#             autohealing, ~94/week) are different events at different layers.
#             They get separate sources in fact_event; neither substitutes for
#             the other.
#   latency   RepairNodePool lands 0.15s after the operation's startTime and
#             0.06s after its endTime; the maintenance channel is slower at
#             8-14s from start, still within 0.2s at the end. A 60s poll
#             averages 30s late, so the log is the faster of the two.
#   noise     Ingestion adds nothing: the ~1,000 daily "Cluster is running
#             incompatible operation" rows are falcon retrying a delete, they
#             are severity=ERROR, and the filter above has always taken them.
#             fact_event collapses them by occurrences rather than dropping
#             them -- that retry storm is itself worth seeing once a day.
#
#   maintenance_events   node-pool upgrades and planned VM maintenance, as a
#                        RUNNING -> SUCCEEDED|CANCELLED state machine per event
#   cloudaudit activity  the NOTICE-level start and end of each cluster
#                        operation. Failures already arrive via severity>=ERROR
#                        with their status message (GCE_STOCKOUT, reservation
#                        capacity, IG timeout) -- the reason a maintenance turns
#                        CANCELLED a fraction of a second later
#   cloudaudit system_event  Google-initiated VM actions:
#                        compute.instances.repair.recreateInstance is node
#                        auto-repair, migrateOnHostMaintenance is live migration
FILTER='
(
  jsonPayload.message:"completed step"
  OR textPayload:"completed step"
  OR severity>=ERROR
  OR log_id("events")
  OR log_id("container.googleapis.com/cluster-autoscaler-visibility")
  OR log_id("tpu.googleapis.com/runtime_monitor")
  OR log_id("ml_diagnostics_workload_event")
  OR log_id("maintenance.googleapis.com/maintenance_events")
  OR (log_id("cloudaudit.googleapis.com/activity")
      AND protoPayload.serviceName="container.googleapis.com"
      AND NOT protoPayload.methodName:"List"
      AND NOT protoPayload.methodName:"Get"
      AND (operation.first=true OR operation.last=true))
  OR (log_id("cloudaudit.googleapis.com/system_event")
      AND protoPayload.methodName:"compute.instances.")
  -- All Capacity group maintenance: the reservation / block / sub-block notice
  -- that arrives ~90 days ahead, plus its start and completion. Matched across
  -- both audit logs and without pinning serviceName, because these are
  -- compute.googleapis.com rather than container.googleapis.com and the clause
  -- above is scoped to GKE -- an earlier version only looked at system_event
  -- and would have missed the notice entirely if it lands in activity.
  -- Nothing to observe in this project yet: All Capacity is on
  -- (schedulingType GROUPED on ghostfish-luwqsqv4va7tk) but no group
  -- maintenance has been scheduled in the retained window, and the cadence is
  -- no more than once every 90 days.
  OR ((log_id("cloudaudit.googleapis.com/system_event")
       OR log_id("cloudaudit.googleapis.com/activity"))
      AND protoPayload.methodName:"GroupMaintenance")
  OR log_id("mlobs-smoketest")
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
