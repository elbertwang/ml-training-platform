#!/bin/bash
# One-time GCP setup for ML Training Platform
# Run this script after connecting GitHub repo to Cloud Build in Console
set -euo pipefail

PROJECT_ID="tpu-launchpad-playground"
CLUSTER="shun-elm-poc-gke"
REGION="us-central1"
REPO_OWNER="elbertwang"
REPO_NAME="ml-training-platform"

echo "=== ML Training Platform Setup ==="
echo "Project: $PROJECT_ID"
echo "Cluster: $CLUSTER"
echo "Region: $REGION"
echo ""

# 1. Grant Cloud Build SA access to GKE
echo "[1/4] Granting Cloud Build SA access to GKE..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/container.developer" \
  --condition=None --quiet

# 2. Create Artifact Registry (idempotent)
echo "[2/4] Creating Artifact Registry..."
gcloud artifacts repositories create ml-training-images \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT_ID" 2>/dev/null && echo "  Created." || echo "  Already exists."

# 3. Create Cloud Build Triggers
echo "[3/4] Creating Cloud Build triggers..."

# PR Check Trigger
gcloud builds triggers create github \
  --repo-name="$REPO_NAME" \
  --repo-owner="$REPO_OWNER" \
  --pull-request-pattern='^(job|feature)/.*$' \
  --build-config=infra/cloudbuild/cloudbuild-pr.yaml \
  --name=ml-platform-pr-check \
  --project="$PROJECT_ID" 2>/dev/null && echo "  PR check trigger created." || echo "  PR check trigger already exists."

# Deploy Trigger
gcloud builds triggers create github \
  --repo-name="$REPO_NAME" \
  --repo-owner="$REPO_OWNER" \
  --branch-pattern='^main$' \
  --build-config=infra/cloudbuild/cloudbuild-deploy.yaml \
  --name=ml-platform-deploy \
  --project="$PROJECT_ID" 2>/dev/null && echo "  Deploy trigger created." || echo "  Deploy trigger already exists."

# 4. Create Cloud Monitoring Dashboard
echo "[4/4] Creating Cloud Monitoring Dashboard..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gcloud monitoring dashboards create \
  --config-from-file="$SCRIPT_DIR/../monitoring/dashboard.json" \
  --project="$PROJECT_ID" 2>/dev/null && echo "  Dashboard created." || echo "  Dashboard may already exist (check Console)."

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Connect GitHub repo in GCP Console:"
echo "     https://console.cloud.google.com/cloud-build/repositories?project=$PROJECT_ID"
echo "  2. If triggers failed above, re-run after connecting GitHub"
echo "  3. Grant team permissions:"
echo "     gcloud projects add-iam-policy-binding $PROJECT_ID \\"
echo "       --member='group:algo-team@your-domain.com' \\"
echo "       --role='roles/logging.viewer'"
echo "     gcloud projects add-iam-policy-binding $PROJECT_ID \\"
echo "       --member='group:algo-team@your-domain.com' \\"
echo "       --role='roles/monitoring.viewer'"
echo "     gcloud projects add-iam-policy-binding $PROJECT_ID \\"
echo "       --member='group:algo-team@your-domain.com' \\"
echo "       --role='roles/hypercomputecluster.viewer'"
echo ""
echo "Dashboard: https://console.cloud.google.com/monitoring/dashboards?project=$PROJECT_ID"
echo "Cluster Director: https://console.cloud.google.com/cluster-director?project=$PROJECT_ID"
