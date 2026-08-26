#!/bin/bash
# Deploy the per-job Grafana dashboard to Cloud Run. Idempotent.
#
#   PROJECT_ID=tpu-for-training ./deploy.sh
#
# Why Cloud Run rather than GKE: nothing here is stateful -- dashboards and
# datasources are provisioned from the image and Grafana's SQLite is throwaway
# -- so a serverless service scales to zero, costs nothing idle, and can be
# deleted without touching a cluster other people share.
#
# ---------------------------------------------------------------------------
# Auth model: plain Cloud Run IAM.
#
# The service is private (--no-allow-unauthenticated); viewers hold
# roles/run.invoker and reach it through `gcloud run services proxy`. Grafana
# itself runs anonymous with the Admin role: a second password buys nothing once
# Google has already proved the identity, and two layers would both want the
# `Authorization` header and fight over it.
#
# ENABLE_IAP=1 switches to IAP, which is nicer -- a shareable URL instead of a
# local proxy. It is not the default because it needs a prerequisite this script
# cannot satisfy: the project must have an OAuth consent screen, and the IAP
# OAuth Admin API that used to create one was permanently shut down on
# 2026-03-19. Without it IAP fails with "Error code 9" (failed OAuth redirect)
# and the consent screen has to be configured by hand in the Cloud Console.
#
# The trap, learned the hard way in tpu-for-training: enabling IAP breaks the
# proxy too. IAP intercepts every request to the service, including
# IAM-authenticated ones, rejecting them with "Invalid IAP credentials: Invalid
# JWT audience" because it expects an audience of an OAuth client that does not
# exist. A half-configured IAP therefore leaves no way in at all, and the two
# doors fail with different messages, which reads like two separate problems.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../../lib/gcp.sh"

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-mlobs-grafana}"
REPO="${REPO:-mlobs}"
SA_NAME="${SA_NAME:-mlobs-grafana}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/grafana:v1"
ENABLE_IAP="${ENABLE_IAP:-0}"   # read the auth-model note above first

require_token

echo "=== Service account ==="
SA=$(ensure_service_account "$PROJECT_ID" "$SA_NAME" "Grafana for ML observability")
echo "  ${SA}"

# Running a query is a project-level permission, so jobUser must be granted
# there. Reading data is not, and an earlier version granted
# roles/bigquery.dataViewer project-wide -- which in tpu-for-training would have
# let the dashboard read every dataset in a customer's production project,
# including `defaultLink`, i.e. all their logs. Read is scoped to the two
# datasets the panels query. Never write: every panel is a SELECT.
#
# The other two datasources talk to GCP directly rather than through BigQuery
# and each needs its own read scope. Missing monitoring.viewer is invisible
# until someone opens the dashboard -- the Cloud Monitoring panels render "No
# data", indistinguishable from a job that genuinely has no metrics -- which is
# how it survived the first production deploy unnoticed.
#   logging.viewer     Cloud Logging datasource; read-only, excludes Data Access logs
#   monitoring.viewer  Cloud Monitoring datasource; timeSeries.list
grant_project_roles "$PROJECT_ID" "$SA" \
  roles/bigquery.jobUser roles/logging.viewer roles/monitoring.viewer
grant_dataset_access "$PROJECT_ID" "$SA" READER mlobs_raw mlobs_core

echo "=== Image ==="
ensure_artifact_repo "$PROJECT_ID" "$REGION" "$REPO"
python3 "${HERE}/build_dashboard.py" --project "$PROJECT_ID" --out "${HERE}/dashboards/job.json"
gcloud builds submit "$HERE" --project "$PROJECT_ID" --region "$REGION" \
  --tag "$IMAGE" --quiet >/dev/null
echo "  ${IMAGE}"

IAP_FLAG="--no-iap"
if [[ "$ENABLE_IAP" == "1" ]]; then
  IAP_FLAG="--iap"
  echo "=== IAP prerequisites ==="
  # `--iap` provisions the IAP service agent itself, but on a project where IAP
  # has never run, that races. The first deploy into tpu-for-training printed
  # "Setting IAP service agent...warning" followed by "Setting IAM policy
  # failed", left the invoker policy empty, and every browser hit came back
  # "You don't have access" -- while the IAP IAM policy read back perfectly
  # correct, which is what made it hard to see. Creating the identity up front
  # makes the deploy's own attempt a no-op instead of a race.
  gcloud beta services identity create --service=iap.googleapis.com \
    --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
  IAP_SA="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"
  echo "  ${IAP_SA}"
fi

deploy_service() {
  gcloud beta run deploy "$SERVICE" --project "$PROJECT_ID" --region "$REGION" \
    --image "$IMAGE" --service-account "$SA" \
    --set-env-vars "MLOBS_PROJECT=${PROJECT_ID},GF_AUTH_ANONYMOUS_ENABLED=true,GF_AUTH_ANONYMOUS_ORG_ROLE=Admin,GF_AUTH_DISABLE_LOGIN_FORM=true,GF_AUTH_BASIC_ENABLED=false" \
    "$IAP_FLAG" --no-allow-unauthenticated --port 8080 --memory 1Gi --cpu 1 \
    --min-instances 0 --max-instances 2 --timeout 300 --quiet >/dev/null
}

echo "=== Deploy ==="
deploy_service

if [[ "$ENABLE_IAP" == "1" ]]; then
  # Resource-level IAM needs the resource to exist, so the invoker grant lands
  # after the first deploy -- and IAP only picks up a new invoker on the next
  # revision. Google's own docs say to redeploy if you granted Invoker and
  # still get permission denied; doing it here avoids leaving a service that
  # looks deployed but rejects everything.
  if gcloud run services get-iam-policy "$SERVICE" --project "$PROJECT_ID" \
       --region "$REGION" --format="value(bindings.members)" 2>/dev/null \
       | grep -q "$IAP_SA"; then
    echo "  IAP agent already had run.invoker"
  else
    # Needs roles/run.admin. roles/editor does NOT include run.services.setIamPolicy.
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
  echo "  Each viewer runs, on a machine where they have logged in to gcloud:"
  echo "    gcloud run services proxy ${SERVICE} \\"
  echo "      --project ${PROJECT_ID} --region ${REGION} --port 8080"
  echo
  echo "  Dashboard:      http://localhost:8080/d/mlobs-job"
  echo "  One job's page: http://localhost:8080/d/mlobs-job?var-job_key=<JOB>"
  echo
  echo "  (${URL} rejects anonymous requests with 403. That is expected.)"
fi
