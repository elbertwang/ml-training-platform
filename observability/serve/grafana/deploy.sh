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
# Auth model: **IAP is the only authentication layer.** Grafana itself runs
# anonymous with the Admin role. Two layers would both want the `Authorization`
# header and fight over it, and a second password buys nothing when IAP already
# proves a Google identity. Access is granted per user with
# roles/iap.httpsResourceAccessor.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-mlobs-grafana}"
REPO="${REPO:-mlobs}"
SA_NAME="${SA_NAME:-mlobs-grafana}"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/grafana:v1"
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
# jobUser lets it run queries; dataViewer lets it read mlobs_*. It never needs
# write access -- every dashboard panel is a SELECT.
for ROLE in roles/bigquery.jobUser roles/bigquery.dataViewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA" --role="$ROLE" --condition=None --quiet >/dev/null
done
echo "  granted bigquery.jobUser + bigquery.dataViewer"

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

echo "=== Deploy ==="
gcloud beta run deploy "$SERVICE" --project "$PROJECT_ID" --region "$REGION" \
  --image "$IMAGE" --service-account "$SA" \
  --set-env-vars "MLOBS_PROJECT=${PROJECT_ID},GF_AUTH_ANONYMOUS_ENABLED=true,GF_AUTH_ANONYMOUS_ORG_ROLE=Admin,GF_AUTH_DISABLE_LOGIN_FORM=true,GF_AUTH_BASIC_ENABLED=false" \
  --iap --no-allow-unauthenticated --port 8080 --memory 1Gi --cpu 1 \
  --min-instances 0 --max-instances 2 --timeout 300 --quiet >/dev/null

URL=$(gcloud run services describe "$SERVICE" --project "$PROJECT_ID" \
      --region "$REGION" --format="value(status.url)")

echo "=== Access ==="
echo "  Grant each viewer:"
echo "    gcloud beta iap web add-iam-policy-binding --project ${PROJECT_ID} \\"
echo "      --resource-type=cloud-run --service=${SERVICE} --region=${REGION} \\"
echo "      --member=user:SOMEONE@example.com --role=roles/iap.httpsResourceAccessor"
echo
echo "  Dashboard:      ${URL}/d/mlobs-job"
echo "  One job's page: ${URL}/d/mlobs-job?var-job_key=<JOB>"
