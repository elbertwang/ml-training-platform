#!/bin/bash
# Put the incremental refresh on a schedule. Idempotent.
#
#   PROJECT_ID=tpu-for-training ./deploy.sh
#
# Cadence is 30 minutes, not the 15 the model was originally sized for, and the
# reason is architectural rather than frugal. Since the dashboard grew its Cloud
# Monitoring and Cloud Logging panels, the live view no longer comes from
# BigQuery at all -- those two datasources are read straight from GCP at query
# time. BigQuery now carries history, ranking and cross-channel joins, none of
# which decay in half an hour. dim_pod is still a full rebuild at ~3.6 GB, which
# makes cadence most of the running cost: ~$65/month at 15 minutes, ~$32 at 30.
#
# See docs/logs.md for the split, and its TBD-2 for why dim_pod should
# eventually accumulate rather than rebuild -- that would cut this again.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
source "${ROOT}/lib/gcp.sh"

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
REGION="${REGION:-us-central1}"
JOB="${JOB:-mlobs-refresh}"
REPO="${REPO:-mlobs}"
SA_NAME="${SA_NAME:-mlobs-refresh}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/refresh:v1"
SCHEDULE="${SCHEDULE:-*/30 * * * *}"
MLDIAG_LOCATIONS="${MLDIAG_LOCATIONS:-us-central1}"

require_token

echo "=== APIs ==="
gcloud services enable cloudscheduler.googleapis.com --project "$PROJECT_ID" --quiet >/dev/null
echo "  cloudscheduler ready"

echo "=== Service accounts ==="
SA=$(ensure_service_account "$PROJECT_ID" "$SA_NAME" "ML observability incremental refresh")
SCHED_SA=$(ensure_service_account "$PROJECT_ID" "mlobs-scheduler" "Triggers the ML observability refresh")
echo "  ${SA}"
echo "  ${SCHED_SA}"

# Unlike the Grafana reader this one writes, but only into mlobs_*. The
# project-level roles are exactly the read scopes the collectors need:
#   monitoring.viewer          timeSeries.list for the metric export
#   hypercomputecluster.viewer the ML Diagnostics REST API
#   run.viewer                 the entrypoint's own overlap check, which lists
#                              this job's executions before starting work
#   container.viewer           nodePools.list, for the node pool -> instance
#                              group hash mapping that turns a maintenance
#                              event's pool name into the jobs running on it
# Deliberately NOT bigquery.dataViewer project-wide: the model never reads
# defaultLink, it is built entirely off the sink tables.
grant_project_roles "$PROJECT_ID" "$SA" \
  roles/bigquery.jobUser roles/monitoring.viewer \
  roles/hypercomputecluster.viewer roles/run.viewer roles/container.viewer
grant_dataset_access "$PROJECT_ID" "$SA" WRITER mlobs_raw mlobs_core

echo "=== Image ==="
ensure_artifact_repo "$PROJECT_ID" "$REGION" "$REPO"
# Built from the observability root because the image needs collect/ and model/,
# with cloudbuild.yaml naming the Dockerfile so nothing has to be copied around.
# An earlier version shuffled the Dockerfile into the repo root and deleted it
# on a trap, which broke whenever the script exited early.
gcloud builds submit "$ROOT" --project "$PROJECT_ID" --region "$REGION" \
  --config "${HERE}/cloudbuild.yaml" \
  --substitutions "_IMAGE=${IMAGE}" --quiet >/dev/null
echo "  ${IMAGE}"

echo "=== Cloud Run job ==="
# --task-timeout stays under the hour the metadata token is valid for; see
# entrypoint.sh. --max-retries 1 because every step is idempotent (a bounded
# DELETE-then-INSERT inside a transaction, or a CREATE OR REPLACE) but a
# genuinely broken run should surface rather than loop.
ARGS=(--project "$PROJECT_ID" --region "$REGION" --image "$IMAGE"
      --service-account "$SA"
      --set-env-vars "PROJECT_ID=${PROJECT_ID},REGION=${REGION},MLDIAG_LOCATIONS=${MLDIAG_LOCATIONS},METRIC_HOURS=1"
      --memory 2Gi --cpu 1 --task-timeout 45m --max-retries 1 --quiet)
if gcloud run jobs describe "$JOB" --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
  gcloud run jobs update "$JOB" "${ARGS[@]}" >/dev/null
  echo "  updated"
else
  gcloud run jobs create "$JOB" "${ARGS[@]}" >/dev/null
  echo "  created"
fi

# ---------------------------------------------------------------------------
# The node pool snapshot runs on its own, far more often than the model.
#
# falcon creates a node pool per job and deletes it when the job ends, so a pool
# missed between two snapshots can never be resolved afterwards -- the audit log
# records the create and the delete but carries no instance group, which is the
# only bridge from a node name to its pool. At a 30-minute cadence 39% of busy
# chip-hours landed in an "unresolved" capacity class; five minutes narrows the
# window it can hide in. It reuses the refresh image and overrides the command,
# so there is nothing extra to build: one API call and a small load, a few
# seconds per run.
POOLSNAP="${POOLSNAP:-mlobs-poolsnap}"
SNAP_ARGS=(--project "$PROJECT_ID" --region "$REGION" --image "$IMAGE"
           --service-account "$SA"
           --command python3
           --args "/app/collect/node_pool_snapshot.py,--project,${PROJECT_ID}"
           --set-env-vars "PROJECT_ID=${PROJECT_ID}"
           --memory 512Mi --cpu 1 --task-timeout 5m --max-retries 1 --quiet)
if gcloud run jobs describe "$POOLSNAP" --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
  gcloud run jobs update "$POOLSNAP" "${SNAP_ARGS[@]}" >/dev/null && echo "  ${POOLSNAP} updated"
else
  gcloud run jobs create "$POOLSNAP" "${SNAP_ARGS[@]}" >/dev/null && echo "  ${POOLSNAP} created"
fi
gcloud run jobs add-iam-policy-binding "$POOLSNAP" --project "$PROJECT_ID" \
  --region "$REGION" --member="serviceAccount:${SCHED_SA}" \
  --role=roles/run.invoker --quiet >/dev/null 2>&1 || true
SNAP_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${POOLSNAP}:run"
SNAP_SARGS=(--project "$PROJECT_ID" --location "$REGION" --schedule "*/5 * * * *"
            --uri "$SNAP_URI" --http-method POST --time-zone UTC
            --oauth-service-account-email "$SCHED_SA" --attempt-deadline 5m --quiet)
if gcloud scheduler jobs describe "$POOLSNAP" --project "$PROJECT_ID" --location "$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$POOLSNAP" "${SNAP_SARGS[@]}" >/dev/null && echo "  ${POOLSNAP} schedule updated: */5"
else
  gcloud scheduler jobs create http "$POOLSNAP" "${SNAP_SARGS[@]}" >/dev/null && echo "  ${POOLSNAP} schedule created: */5"
fi

echo "=== Scheduler ==="
# The scheduler gets its own identity holding nothing but run.invoker. Reusing
# the refresh account would mean anything able to impersonate the writer could
# also trigger it.
for ATTEMPT in 1 2 3 4 5 6; do   # same SA creation-propagation delay as above
  if gcloud run jobs add-iam-policy-binding "$JOB" --project "$PROJECT_ID" \
       --region "$REGION" --member="serviceAccount:${SCHED_SA}" \
       --role=roles/run.invoker --quiet >/dev/null 2>&1; then
    break
  fi
  [[ $ATTEMPT -eq 6 ]] && { echo "  FAILED to grant run.invoker" >&2; exit 1; }
  sleep 10
done
echo "  ${SCHED_SA} may invoke ${JOB}"

URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB}:run"
SARGS=(--project "$PROJECT_ID" --location "$REGION" --schedule "$SCHEDULE"
       --uri "$URI" --http-method POST --time-zone UTC
       --oauth-service-account-email "$SCHED_SA"
       --attempt-deadline 30m --quiet)
if gcloud scheduler jobs describe "$JOB" --project "$PROJECT_ID" --location "$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$JOB" "${SARGS[@]}" >/dev/null
  echo "  updated: ${SCHEDULE}"
else
  gcloud scheduler jobs create http "$JOB" "${SARGS[@]}" >/dev/null
  echo "  created: ${SCHEDULE}"
fi

echo
echo "  Run once now:  gcloud run jobs execute ${JOB} --project ${PROJECT_ID} --region ${REGION}"
echo "  Pause:         gcloud scheduler jobs pause ${JOB} --project ${PROJECT_ID} --location ${REGION}"
