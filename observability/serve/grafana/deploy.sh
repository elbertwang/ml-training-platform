#!/bin/bash
# Deploy the per-job Grafana dashboard to Cloud Run. Idempotent.
#
#   PROJECT_ID=tpu-launchpad-playground ./deploy.sh
#
# Why Cloud Run rather than GKE: nothing here is stateful (dashboards and the
# datasource are provisioned from the image, Grafana's SQLite is throwaway), so
# a serverless service scales to zero, costs nothing idle, and can be deleted
# without touching a cluster that other people share.
#
# Auth model: **plain Cloud Run IAM.** The service is private
# (--no-allow-unauthenticated) and viewers reach it through
# `gcloud run services proxy`, authenticated by roles/run.invoker. Grafana
# itself runs anonymous with the Admin role -- a second password buys nothing
# once Google has already proved the identity, and two layers would both want
# the `Authorization` header and fight over it.
#
# IAP would be nicer -- a plain shareable URL instead of a local proxy -- and
# ENABLE_IAP=1 turns it on. It is NOT the default because it needs a
# prerequisite this script cannot satisfy: the project must have a configured
# OAuth consent screen, and the IAP OAuth Admin API that used to create one was
# permanently shut down on 2026-03-19. Without it IAP fails with "Error code 9"
# (failed OAuth redirect) and the consent screen has to be configured by hand in
# the Cloud Console.
#
# The trap, learned the hard way in tpu-for-training: **enabling IAP breaks the
# proxy too.** IAP intercepts every request to the service, including
# IAM-authenticated ones, and rejects them with "Invalid IAP credentials:
# Invalid JWT audience" because it expects an audience of the IAP OAuth client
# that does not exist. So a half-configured IAP leaves no way in at all, which
# is exactly what happened: both access paths failed for the same single cause.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-mlobs-grafana}"
REPO="${REPO:-mlobs}"
SA_NAME="${SA_NAME:-mlobs-grafana}"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/grafana:v1"
ENABLE_IAP="${ENABLE_IAP:-0}"   # see the auth-model note above before turning this on
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

echo "=== Service account ==="
if gcloud iam service-accounts describe "$SA" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "  exists"
else
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT_ID" \
    --display-name="Grafana for ML observability" --quiet >/dev/null
  echo "  created"
fi
# Running a query is a project-level permission, so jobUser has to be granted
# there. Reading data does not: an earlier version also granted
# roles/bigquery.dataViewer project-wide, which in tpu-for-training would have
# let the dashboard read every dataset in a customer's production project --
# including `defaultLink`, i.e. all their logs. Grant read on the two datasets
# the dashboards actually query instead. Never write: every panel is a SELECT.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/bigquery.jobUser \
  --condition=None --quiet >/dev/null
echo "  granted bigquery.jobUser (project)"

# Dataset-level ACL rather than IAM: `bq get-iam-policy` on a dataset needs an
# allowlist tpu-for-training does not have. The dataset resource's `access`
# array is the supported path, and READER there is exactly dataViewer.
#
# `bq update --source` replaces the dataset config wholesale, so this is a
# read-modify-write that then verifies no pre-existing entry disappeared. On a
# customer's production dataset, silently dropping someone else's grant would
# be a much worse bug than the over-broad permission this replaced.
for DS in mlobs_raw mlobs_core; do
  BEFORE=$(mktemp); PATCH=$(mktemp)
  bq --project_id="$PROJECT_ID" show --format=prettyjson "${PROJECT_ID}:${DS}" > "$BEFORE"
  "${HERE}/dataset_reader.py" --mode=patch --before="$BEFORE" --out="$PATCH" --sa="$SA"
  bq --project_id="$PROJECT_ID" update --source "$PATCH" "${PROJECT_ID}:${DS}" >/dev/null
  bq --project_id="$PROJECT_ID" show --format=prettyjson "${PROJECT_ID}:${DS}" \
    | "${HERE}/dataset_reader.py" --mode=verify --before="$BEFORE" --sa="$SA"
  rm -f "$BEFORE" "$PATCH"
  echo "  granted dataViewer (READER) on ${DS}"
done

# The other two datasources read GCP directly rather than through BigQuery, and
# each needs its own project-level read scope. Missing monitoring.viewer is
# invisible until someone opens the dashboard: the Cloud Monitoring panels just
# render "No data", exactly as they would for a job with no metrics. That is how
# it survived the first production deploy unnoticed.
#   logging.viewer     Cloud Logging datasource; read-only over log entries,
#                      and does not include private (Data Access) logs
#   monitoring.viewer  Cloud Monitoring datasource; timeSeries.list
for ROLE in roles/logging.viewer roles/monitoring.viewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA" --role="$ROLE" \
    --condition=None --quiet >/dev/null
done
echo "  granted logging.viewer + monitoring.viewer (project)"

echo "=== Artifact Registry ==="
gcloud artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 \
  || gcloud artifacts repositories create "$REPO" --repository-format=docker \
       --location="$REGION" --project "$PROJECT_ID" --quiet >/dev/null
echo "  ${REPO} ready"

echo "=== Dashboard JSON ==="
python3 "${HERE}/build_dashboard.py" --project "$PROJECT_ID" --out "${HERE}/dashboards/job.json"

echo "=== Build image ==="
gcloud builds submit "$HERE" --project "$PROJECT_ID" --region "$REGION" \
  --tag "$IMAGE" --quiet >/dev/null
echo "  ${IMAGE}"

IAP_FLAG="--no-iap"
if [[ "$ENABLE_IAP" == "1" ]]; then
  IAP_FLAG="--iap"
  echo "=== IAP prerequisites ==="
  # `--iap` provisions the IAP service agent itself, but on a project where IAP
  # has never run that provisioning races: the first deploy into tpu-for-training
  # printed "Setting IAP service agent...warning" followed by "Setting IAM policy
  # failed", left the service's invoker policy empty, and every browser hit came
  # back "You don't have access" despite a correct-looking IAP IAM policy.
  # Creating the identity up front makes the deploy's own attempt a no-op.
  gcloud beta services identity create --service=iap.googleapis.com \
    --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
  IAP_SA="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"
  echo "  ${IAP_SA}"
fi

echo "=== Deploy ==="
deploy_service() {
  gcloud beta run deploy "$SERVICE" --project "$PROJECT_ID" --region "$REGION" \
    --image "$IMAGE" --service-account "$SA" \
    --set-env-vars "MLOBS_PROJECT=${PROJECT_ID},GF_AUTH_ANONYMOUS_ENABLED=true,GF_AUTH_ANONYMOUS_ORG_ROLE=Admin,GF_AUTH_DISABLE_LOGIN_FORM=true,GF_AUTH_BASIC_ENABLED=false" \
    "$IAP_FLAG" --no-allow-unauthenticated --port 8080 --memory 1Gi --cpu 1 \
    --min-instances 0 --max-instances 2 --timeout 300 --quiet >/dev/null
}
deploy_service

if [[ "$ENABLE_IAP" == "1" ]]; then
  # The service must exist before its resource-level IAM can be set, so the
  # invoker grant lands after the first deploy -- and IAP only picks up a new
  # invoker on the next revision. Google's own docs say to redeploy if you
  # granted Invoker and still get permission denied.
  if gcloud run services get-iam-policy "$SERVICE" --project "$PROJECT_ID" \
       --region "$REGION" --format="value(bindings.members)" 2>/dev/null \
       | grep -q "$IAP_SA"; then
    echo "  IAP agent already had run.invoker"
  else
    # Needs roles/run.admin; roles/editor does NOT include run.services.setIamPolicy.
    gcloud run services add-iam-policy-binding "$SERVICE" --project "$PROJECT_ID" \
      --region "$REGION" --member="serviceAccount:${IAP_SA}" \
      --role=roles/run.invoker --quiet >/dev/null
    echo "  granted run.invoker to the IAP agent; redeploying so IAP picks it up"
    deploy_service
  fi
fi

URL=$(gcloud run services describe "$SERVICE" --project "$PROJECT_ID" \
      --region "$REGION" --format="value(status.url)")

echo "=== Access ==="
if [[ "$ENABLE_IAP" == "1" ]]; then
  echo "  Grant each viewer:"
  echo "    gcloud beta iap web add-iam-policy-binding --project ${PROJECT_ID} \\"
  echo "      --resource-type=cloud-run --service=${SERVICE} --region=${REGION} \\"
  echo "      --member=user:SOMEONE@example.com --role=roles/iap.httpsResourceAccessor"
  echo
  echo "  Dashboard:      ${URL}/d/mlobs-job"
  echo "  One job's page: ${URL}/d/mlobs-job?var-job_key=<JOB>"
else
  echo "  Grant each viewer:"
  echo "    gcloud run services add-iam-policy-binding ${SERVICE} \\"
  echo "      --project ${PROJECT_ID} --region ${REGION} \\"
  echo "      --member=user:SOMEONE@example.com --role=roles/run.invoker"
  echo
  echo "  Each viewer then runs, on a machine where they have logged in to gcloud:"
  echo "    gcloud run services proxy ${SERVICE} \\"
  echo "      --project ${PROJECT_ID} --region ${REGION} --port 8080"
  echo
  echo "  Dashboard:      http://localhost:8080/d/mlobs-job"
  echo "  One job's page: http://localhost:8080/d/mlobs-job?var-job_key=<JOB>"
  echo
  echo "  (${URL} rejects anonymous requests with 403 -- that is expected.)"
fi
