#!/bin/bash
# Deploy mlobs-notify. Idempotent, and dry-run by default.
#
#   PROJECT_ID=tpu-for-training ./deploy.sh
#   PROJECT_ID=tpu-for-training DRY_RUN=0 ./deploy.sh    # actually send
#
# DRY_RUN defaults to 1 and the deploy will not silently flip it: a
# notification cannot be recalled, and the rollout this was written for is
# "run dry for a week, compare the ledger against what gke-ops-monitor actually
# sent, then turn it on". Passing DRY_RUN=0 is that second step, done on purpose.
#
# Two triggers are wired:
#   /pubsub  a Log Router push subscription. The intended mode. Needs the sink's
#            writer identity to hold pubsub.publisher on the topic, which is a
#            resource-level grant roles/editor does not include -- if the
#            subscription step below fails, that is why, and /poll keeps working.
#   /poll    Cloud Scheduler every few minutes. Catch-up after an outage, and
#            the only path until that grant exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/gcp.sh"

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-mlobs-notify}"
REPO="${REPO:-mlobs}"
SA_NAME="${SA_NAME:-mlobs-notify}"
TOPIC="${TOPIC:-mlobs-events}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/notify:v1"
DRY_RUN="${DRY_RUN:-1}"
POLL_SCHEDULE="${POLL_SCHEDULE:-*/5 * * * *}"
require_token

echo "=== Service account ==="
SA=$(ensure_service_account "$PROJECT_ID" "$SA_NAME" "ML observability notifier")
echo "  ${SA}"

# It reads the model to attribute an event and writes one ledger table. jobUser
# is project-level because running a query is; the data grants are scoped to the
# two datasets, never project-wide dataViewer -- that would hand it defaultLink,
# i.e. every log in the project.
grant_project_roles "$PROJECT_ID" "$SA" roles/bigquery.jobUser
grant_dataset_access "$PROJECT_ID" "$SA" WRITER mlobs_core
grant_dataset_access "$PROJECT_ID" "$SA" READER mlobs_raw

echo "=== Schema ==="
bq --project_id="$PROJECT_ID" query --use_legacy_sql=false < "${HERE}/schema.sql" >/dev/null
echo "  fact_notification ready"

echo "=== Image ==="
ensure_artifact_repo "$PROJECT_ID" "$REGION" "$REPO"
gcloud builds submit "$HERE" --project "$PROJECT_ID" --region "$REGION" \
  --tag "$IMAGE" --quiet >/dev/null
echo "  ${IMAGE}"

echo "=== Service ==="
# The DingTalk webhook is read from the existing bridge's configuration rather
# than duplicated here, so there is one place to rotate it.
WEBHOOK="${DINGTALK_WEBHOOK:-$(gcloud run services describe maxtext-alert-dingtalk \
  --project "$PROJECT_ID" --region "$REGION" \
  --format='value(spec.template.spec.containers[0].env)' 2>/dev/null \
  | tr ';' '\n' | grep -o "'DINGTALK_WEBHOOK', 'value': '[^']*'" \
  | sed "s/.*'value': '//;s/'$//" || true)}"
[[ -n "$WEBHOOK" ]] && echo "  webhook: inherited from maxtext-alert-dingtalk" \
                    || echo "  webhook: NOT set -- service stays dry-run regardless"

gcloud run deploy "$SERVICE" --project "$PROJECT_ID" --region "$REGION" \
  --image "$IMAGE" --service-account "$SA" \
  --set-env-vars "MLOBS_PROJECT=${PROJECT_ID},DRY_RUN=${DRY_RUN},AT_USER_IDS=${AT_USER_IDS:-},DINGTALK_WEBHOOK=${WEBHOOK}" \
  --no-allow-unauthenticated --port 8080 --memory 512Mi --cpu 1 \
  --min-instances 0 --max-instances 3 --timeout 300 --quiet >/dev/null
URL=$(gcloud run services describe "$SERVICE" --project "$PROJECT_ID" \
      --region "$REGION" --format="value(status.url)")
echo "  ${URL}  (DRY_RUN=${DRY_RUN})"

echo "=== Push subscription ==="
PUSH_SA="${SA}"
if gcloud pubsub subscriptions describe "${SERVICE}-push" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud pubsub subscriptions update "${SERVICE}-push" --project "$PROJECT_ID" \
    --push-endpoint "${URL}/pubsub" \
    --push-auth-service-account "$PUSH_SA" --quiet >/dev/null && echo "  updated" || echo "  update failed"
else
  gcloud pubsub subscriptions create "${SERVICE}-push" --project "$PROJECT_ID" \
    --topic "$TOPIC" --push-endpoint "${URL}/pubsub" \
    --push-auth-service-account "$PUSH_SA" \
    --ack-deadline 60 --quiet >/dev/null && echo "  created" || {
      echo "  FAILED -- most likely the topic IAM grant is missing; /poll still works"; }
fi
gcloud run services add-iam-policy-binding "$SERVICE" --project "$PROJECT_ID" \
  --region "$REGION" --member="serviceAccount:${SA}" \
  --role=roles/run.invoker --quiet >/dev/null 2>&1 || \
  echo "  note: could not grant run.invoker to itself (needs run.admin)"

echo "=== Poll schedule ==="
URI="${URL}/poll"
SARGS=(--project "$PROJECT_ID" --location "$REGION" --schedule "$POLL_SCHEDULE"
       --uri "$URI" --http-method POST --time-zone UTC
       --oidc-service-account-email "$SA" --oidc-token-audience "$URL"
       --attempt-deadline 5m --quiet)
if gcloud scheduler jobs describe "${SERVICE}-poll" --project "$PROJECT_ID" --location "$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "${SERVICE}-poll" "${SARGS[@]}" >/dev/null
  echo "  updated: ${POLL_SCHEDULE}"
else
  gcloud scheduler jobs create http "${SERVICE}-poll" "${SARGS[@]}" >/dev/null
  echo "  created: ${POLL_SCHEDULE}"
fi

echo
echo "  Smoke test:"
echo "    gcloud logging write mlobs-smoketest \\"
echo "      '{\"probe\":\"notify path\",\"target\":\"tpu-256chips-pool-0-4x8x8\"}' \\"
echo "      --project ${PROJECT_ID} --payload-type=json --severity=WARNING"
echo "    # then, within a few minutes:"
echo "    bq query --use_legacy_sql=false \\"
echo "      'SELECT * FROM \`${PROJECT_ID}.mlobs_core.fact_notification\` ORDER BY notified_at DESC LIMIT 5'"
