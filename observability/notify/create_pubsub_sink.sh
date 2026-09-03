#!/bin/bash
# Route infrastructure events to Pub/Sub so the notifier is pushed, not polling.
# Idempotent.
#
#   PROJECT_ID=tpu-for-training ./create_pubsub_sink.sh
#
# A second sink on the same Log Router, deliberately narrower than the BigQuery
# one. That sink takes everything the model needs -- 1.8M rows a day, most of it
# training output -- and pushing that volume through Pub/Sub to a notifier that
# would discard 99.99% of it is pointless. This filter carries only the channels
# a human would be told about: a few hundred entries a day at the busiest.
#
# The alternative was polling BigQuery every couple of minutes. Push wins for a
# reason that is not latency: it removes the concept of "where did I get to".
# The poller this replaces kept a last_seen.json in GCS and deduplicated against
# it; with push, the log entry's own insertId is the idempotency key and there
# is no cursor to lose.
#
# Attribution does NOT happen here. The message is a raw log entry with no job in
# it -- the notifier looks the job up before composing anything. See notify/main.py.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
TOPIC="${TOPIC:-mlobs-events}"
SINK_NAME="${SINK_NAME:-mlobs-events-notify}"

# mlobs-smoketest is a permanent, never-fired channel. Reserved log names such
# as cloudaudit.googleapis.com/activity cannot be written to, so without a
# channel of our own the only way to exercise this path end to end would be to
# wait for a real node pool upgrade. `gcloud logging write mlobs-smoketest ...`
# makes the drill repeatable and costs nothing when unused.
FILTER='
(
  log_id("maintenance.googleapis.com/maintenance_events")
  OR (log_id("cloudaudit.googleapis.com/activity")
      AND protoPayload.serviceName="container.googleapis.com"
      AND (operation.last=true OR severity>=ERROR))
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

echo "=== Topic ==="
if gcloud pubsub topics describe "$TOPIC" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "  ${TOPIC} exists"
else
  gcloud pubsub topics create "$TOPIC" --project "$PROJECT_ID" --quiet >/dev/null
  echo "  ${TOPIC} created"
fi

echo "=== Sink ==="
DEST="pubsub.googleapis.com/projects/${PROJECT_ID}/topics/${TOPIC}"
if gcloud logging sinks describe "$SINK_NAME" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud logging sinks update "$SINK_NAME" "$DEST" --project "$PROJECT_ID" \
    --log-filter="$FILTER" --quiet >/dev/null
  echo "  ${SINK_NAME} updated"
else
  gcloud logging sinks create "$SINK_NAME" "$DEST" --project "$PROJECT_ID" \
    --log-filter="$FILTER" --quiet >/dev/null
  echo "  ${SINK_NAME} created"
fi

# The sink writes as its own service agent, which has no permissions until
# granted. Without this the sink reports success and silently discards every
# entry -- the failure shows up only in logging.googleapis.com/sink_error.
WRITER=$(gcloud logging sinks describe "$SINK_NAME" --project "$PROJECT_ID" \
         --format="value(writerIdentity)")
gcloud pubsub topics add-iam-policy-binding "$TOPIC" --project "$PROJECT_ID" \
  --member="$WRITER" --role=roles/pubsub.publisher --quiet >/dev/null
echo "  ${WRITER} may publish"

echo
echo "  Smoke test:"
echo "    gcloud logging write mlobs-smoketest \\"
echo "      '{\"probe\":\"notify\",\"target\":\"tpu-256chips-pool-0-4x8x8\"}' \\"
echo "      --project ${PROJECT_ID} --payload-type=json --severity=WARNING"
