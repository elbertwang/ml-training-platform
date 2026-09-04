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
# Auth model: IAP, with Cloud Run IAM as the fallback path.
#
# The service is private either way (--no-allow-unauthenticated). Grafana itself
# runs anonymous with the Admin role: a second password buys nothing once Google
# has proved the identity, and two layers would both want the `Authorization`
# header and fight over it.
#
# Two things gate IAP, and both bit us before they were understood.
#
# 1. The project needs an OAuth consent screen. Without one IAP fails with
#    "Error code 9" (failed OAuth redirect) even though every IAM policy reads
#    correct. Create it with:
#
#      curl -X POST -H "Authorization: Bearer $TOKEN" \
#        https://iap.googleapis.com/v1/projects/<PROJECT>/brands \
#        -d '{"applicationTitle":"...","supportEmail":"<you>@<org>"}'
#
#    gcloud warns this API was turned down on 2026-03-19. That applies to
#    *new* projects; it still works for projects that predate the turndown,
#    which is how tpu-for-training got one. A brand cannot be deleted.
#
# 2. A brand created this way is `orgInternalOnly`, so only accounts inside the
#    project's own organisation can sign in. tpu-for-training sits under
#    antgroup.com, so @antgroup.com users reach the dashboard through IAP and
#    everyone else does not. Flipping it to External is a Cloud Console change
#    on the Google Auth Platform audience page -- and after flipping, the app
#    must also be published, or only accounts on a 100-entry test-user list can
#    sign in. IAP only requests `openid email`, both non-sensitive, so
#    publishing does not require Google verification.
#
# Whoever cannot use IAP uses the proxy instead, which needs only run.invoker.
# It must point at the IAP-free sibling, never at $SERVICE -- IAP intercepts
# every inbound request on its own service, including an IAM-authenticated one
# (see the block above the ${SERVICE}-direct step at the bottom of this file):
#
#   gcloud run services proxy mlobs-grafana-direct --project <P> --region <R> --port 8080
#
# ENABLE_IAP defaults to whatever the deployed service already has, so
# redeploying never silently changes how people get in. On a project with no
# service yet it defaults off, because a fresh project has no consent screen.
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
require_token

# Follow the deployed service rather than defaulting blind: flipping a live
# service's auth mode as a side effect of redeploying would lock out everyone
# who reaches it the other way.
if [[ -z "${ENABLE_IAP:-}" ]]; then
  ENABLE_IAP=$(gcloud run services describe "$SERVICE" --project "$PROJECT_ID" \
                 --region "$REGION" \
                 --format="value(metadata.annotations['run.googleapis.com/iap-enabled'])" \
                 2>/dev/null | grep -q true && echo 1 || echo 0)
fi


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
python3 "${HERE}/build_dashboard.py" --project "$PROJECT_ID" --out-dir "${HERE}/dashboards"
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

# One definition, both services. They differ in exactly one argument -- whether
# IAP is on -- and everything else is shared by construction.
#
# An earlier version deployed $SERVICE from this function and then updated the
# sibling with `--image` alone. The image stayed in step; nothing else did. Add
# an env var, change the memory limit or the instance ceiling, and only one of
# the two would get it, with no error and no obvious symptom -- the pair would
# simply start behaving differently for the two audiences, and the difference
# would surface as a bug report from whichever half was stale.
#
#   $1  service name
#   $2  --iap or --no-iap
deploy_service() {
  gcloud beta run deploy "$1" --project "$PROJECT_ID" --region "$REGION" \
    --image "$IMAGE" --service-account "$SA" \
    --set-env-vars "MLOBS_PROJECT=${PROJECT_ID},GF_AUTH_ANONYMOUS_ENABLED=true,GF_AUTH_ANONYMOUS_ORG_ROLE=Admin,GF_AUTH_DISABLE_LOGIN_FORM=true,GF_AUTH_BASIC_ENABLED=false" \
    "$2" --no-allow-unauthenticated --port 8080 --memory 1Gi --cpu 1 \
    --min-instances 0 --max-instances 2 --timeout 300 --quiet >/dev/null
}

echo "=== Deploy ==="
deploy_service "$SERVICE" "$IAP_FLAG"

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
    deploy_service "$SERVICE" "$IAP_FLAG"
  fi
fi

# IAP is a per-service switch that intercepts *every* inbound request, including
# an IAM-authenticated one carrying an ID token -- those come back "Invalid IAP
# credentials: Invalid JWT audience", which a browser renders as Error code 9.
# So one service cannot serve both IAP users and proxy users.
#
# When the consent screen is Internal that matters, because accounts outside the
# project's organisation cannot sign in through IAP at all and have no way in.
# `${SERVICE}-direct` is the same image with IAP off for exactly those people.
# It is only touched if it already exists -- deploying the pair is a decision
# made once, not something this script imposes on a new project.
#
# Create it with:
#   gcloud beta run deploy ${SERVICE}-direct --image <same image> \
#     --service-account <same SA> --no-iap --no-allow-unauthenticated ...
DIRECT="${SERVICE}-direct"
echo "=== Sibling service without IAP ==="
if gcloud run services describe "$DIRECT" --project "$PROJECT_ID" \
     --region "$REGION" >/dev/null 2>&1; then
  deploy_service "$DIRECT" --no-iap
  echo "  ${DIRECT} redeployed from the same definition"

  # Assert rather than assume. The pair is the one piece of this deployment
  # where being out of step is silent: both services answer, both look healthy,
  # and only the content differs. Comparing the digest each revision actually
  # resolved -- not the tag, which is the same string either way and says
  # nothing -- turns that into a failed deploy.
  digest_of() {
    local rev
    rev=$(gcloud run services describe "$1" --project "$PROJECT_ID" \
          --region "$REGION" --format="value(status.latestReadyRevisionName)")
    gcloud run revisions describe "$rev" --project "$PROJECT_ID" \
      --region "$REGION" --format="value(status.imageDigest)"
  }
  D_MAIN=$(digest_of "$SERVICE")
  D_SIDE=$(digest_of "$DIRECT")
  if [[ "$D_MAIN" == "$D_SIDE" && -n "$D_MAIN" ]]; then
    echo "  both serving ${D_MAIN##*:}"
  else
    echo "  MISMATCH -- ${SERVICE}=${D_MAIN:-?} ${DIRECT}=${D_SIDE:-?}" >&2
    exit 1
  fi
else
  echo "  ${DIRECT} does not exist; skipped."
  echo "  Out-of-org viewers need it -- IAP intercepts every request on"
  echo "  ${SERVICE}, so a proxy to that service cannot work. Create it once:"
  echo "    gcloud beta run deploy ${DIRECT} --project ${PROJECT_ID} \\"
  echo "      --region ${REGION} --image ${IMAGE} --service-account ${SA} \\"
  echo "      --no-iap --no-allow-unauthenticated --port 8080"
  echo "  and every later run of this script keeps it in step."
fi

URL=$(gcloud run services describe "$SERVICE" --project "$PROJECT_ID" \
      --region "$REGION" --format="value(status.url)")

echo "=== Access ==="
if [[ "$ENABLE_IAP" == "1" ]]; then
  echo "  Viewers inside the project's own organisation -- grant IAP access:"
  echo "    gcloud beta iap web add-iam-policy-binding --project ${PROJECT_ID} \\"
  echo "      --resource-type=cloud-run --service=${SERVICE} --region=${REGION} \\"
  echo "      --member=user:SOMEONE@example.com --role=roles/iap.httpsResourceAccessor"
  echo
  echo "  Job index:      ${URL}/d/mlobs-jobs"
  echo "  One job's page: ${URL}/d/mlobs-job?var-job_key=<JOB>"
  echo
  echo "  Viewers OUTSIDE that organisation cannot sign in while the consent"
  echo "  screen is Internal, and cannot bypass IAP on this service either."
  echo "  They go through ${DIRECT} -- NOT ${SERVICE}, which IAP would reject"
  echo "  with Error code 9 however the IAM policy reads:"
  if gcloud run services describe "$DIRECT" --project "$PROJECT_ID" \
       --region "$REGION" >/dev/null 2>&1; then
    echo "    gcloud run services add-iam-policy-binding ${DIRECT} \\"
    echo "      --project ${PROJECT_ID} --region ${REGION} \\"
    echo "      --member=user:SOMEONE@example.com --role=roles/run.invoker"
    echo "    gcloud run services proxy ${DIRECT} \\"
    echo "      --project ${PROJECT_ID} --region ${REGION} --port 8080"
  else
    echo "    ${DIRECT} does not exist yet. Create it with the same image and"
    echo "    service account, plus --no-iap; this script keeps it in sync after."
  fi
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
  echo "  Job index:      http://localhost:8080/d/mlobs-jobs"
  echo "  One job's page: http://localhost:8080/d/mlobs-job?var-job_key=<JOB>"
  echo
  echo "  (${URL} rejects anonymous requests with 403. That is expected.)"
fi
