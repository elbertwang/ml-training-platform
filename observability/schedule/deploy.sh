#!/bin/bash
# Put the incremental refresh on a schedule. Idempotent.
#
#   PROJECT_ID=tpu-for-training ./deploy.sh
#
# Cadence is 30 minutes, not the 15 the model was originally sized for, and the
# reason is architectural rather than frugal. Since the dashboard grew its
# Cloud Monitoring and Cloud Logging panels, the live view no longer comes from
# BigQuery at all -- those two datasources are read straight from GCP at query
# time. BigQuery now carries history, ranking and cross-channel joins, none of
# which decay in half an hour. dim_pod is a full rebuild at ~3.6 GB, so the
# cadence is most of the running cost: 15 min is ~$65/month, 30 min ~$32.
#
# See docs/log-routing.md for the split, and TBD-2 for why dim_pod should
# eventually accumulate rather than rebuild -- that would cut this further.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
REGION="${REGION:-us-central1}"
JOB="${JOB:-mlobs-refresh}"
REPO="${REPO:-mlobs}"
SA_NAME="${SA_NAME:-mlobs-refresh}"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/refresh:v1"
SCHEDULE="${SCHEDULE:-*/30 * * * *}"
MLDIAG_LOCATIONS="${MLDIAG_LOCATIONS:-us-central1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

echo "=== APIs ==="
gcloud services enable cloudscheduler.googleapis.com --project "$PROJECT_ID" --quiet >/dev/null
echo "  cloudscheduler ready"

echo "=== Service account ==="
if gcloud iam service-accounts describe "$SA" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "  exists"
else
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT_ID" \
    --display-name="ML observability incremental refresh" --quiet >/dev/null
  echo "  created"
fi

# Unlike the Grafana reader this one writes, but only into mlobs_*. Project-level
# roles are the two read scopes the collectors need and nothing else:
#   monitoring.viewer          timeSeries.list for the metric export
#   hypercomputecluster.viewer the ML Diagnostics REST API
# It is deliberately NOT granted bigquery.dataViewer project-wide -- it never
# reads defaultLink; the whole model is built off the sink tables.
#
# Retried because a freshly created service account is not immediately visible
# to the IAM policy API: binding a role seconds after `create` fails with
# "Service account ... does not exist", which is a propagation delay, not a
# real error.
for ROLE in roles/bigquery.jobUser roles/monitoring.viewer roles/hypercomputecluster.viewer; do
  for ATTEMPT in 1 2 3 4 5 6; do
    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
         --member="serviceAccount:$SA" --role="$ROLE" \
         --condition=None --quiet >/dev/null 2>&1; then
      break
    fi
    [[ $ATTEMPT -eq 6 ]] && { echo "  FAILED to grant ${ROLE}" >&2; exit 1; }
    sleep 10
  done
done
echo "  granted jobUser + monitoring.viewer + hypercomputecluster.viewer (project)"

# WRITER on the two datasets, via the dataset access array for the same reason
# serve/grafana/deploy.sh uses it: bq get-iam-policy needs an allowlist this
# project does not have. Verified afterwards so a wholesale `bq update` cannot
# silently drop another principal's grant.
for DS in mlobs_raw mlobs_core; do
  BEFORE=$(mktemp); PATCH=$(mktemp)
  bq --project_id="$PROJECT_ID" show --format=prettyjson "${PROJECT_ID}:${DS}" > "$BEFORE"
  "${ROOT}/serve/grafana/dataset_reader.py" --mode=patch --role=WRITER \
    --before="$BEFORE" --out="$PATCH" --sa="$SA"
  bq --project_id="$PROJECT_ID" update --source "$PATCH" "${PROJECT_ID}:${DS}" >/dev/null
  bq --project_id="$PROJECT_ID" show --format=prettyjson "${PROJECT_ID}:${DS}" \
    | "${ROOT}/serve/grafana/dataset_reader.py" --mode=verify --role=WRITER \
        --before="$BEFORE" --sa="$SA"
  rm -f "$BEFORE" "$PATCH"
  echo "  granted dataEditor (WRITER) on ${DS}"
done

echo "=== Build image ==="
# Built from the repo root so the image can COPY collect/ and model/, with a
# .gcloudignore keeping the upload to the few files that matter.
cp "${HERE}/Dockerfile" "${HERE}/entrypoint.sh" "${ROOT}/" 2>/dev/null || true
trap 'rm -f "${ROOT}/Dockerfile" "${ROOT}/entrypoint.sh"' EXIT
cat > "${ROOT}/.gcloudignore" <<'IGNORE'
.git
docs
serve
schedule
tools
*.md
IGNORE
gcloud builds submit "$ROOT" --project "$PROJECT_ID" --region "$REGION" \
  --tag "$IMAGE" --quiet >/dev/null
rm -f "${ROOT}/.gcloudignore"
echo "  ${IMAGE}"

echo "=== Cloud Run job ==="
# --task-timeout stays under the hour the metadata token is valid for; see
# entrypoint.sh. --max-retries 1 because the refresh is idempotent (every step
# is DELETE-then-INSERT over a bounded window or a CREATE OR REPLACE) but a
# genuinely broken run should surface rather than loop.
ARGS=(--project "$PROJECT_ID" --region "$REGION" --image "$IMAGE"
      --service-account "$SA"
      --set-env-vars "PROJECT_ID=${PROJECT_ID},MLDIAG_LOCATIONS=${MLDIAG_LOCATIONS},METRIC_HOURS=1"
      --memory 2Gi --cpu 1 --task-timeout 45m --max-retries 1 --quiet)
if gcloud run jobs describe "$JOB" --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
  gcloud run jobs update "$JOB" "${ARGS[@]}" >/dev/null
  echo "  updated"
else
  gcloud run jobs create "$JOB" "${ARGS[@]}" >/dev/null
  echo "  created"
fi

echo "=== Scheduler ==="
# The scheduler needs its own identity that may invoke the job. Reusing the
# job's SA would let anything that can impersonate the refresh identity also
# trigger it; a separate one keeps run.invoker off the writer.
SCHED_SA="mlobs-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$SCHED_SA" --project "$PROJECT_ID" >/dev/null 2>&1 \
  || gcloud iam service-accounts create mlobs-scheduler --project "$PROJECT_ID" \
       --display-name="Triggers the ML observability refresh" --quiet >/dev/null
for ATTEMPT in 1 2 3 4 5 6; do   # same creation-propagation delay as above
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
