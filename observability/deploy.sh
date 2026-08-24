#!/bin/bash
# Provision the observability platform: datasets, log sink, model objects.
# Idempotent -- safe to re-run.
#
# Location matters: `defaultLink` (the Log Analytics linked dataset) lives in the
# US multi-region, and BigQuery cannot query across locations. The model reads
# from it, so mlobs_raw/mlobs_core must be US as well, not us-central1.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tpu-for-training}"
LOCATION="${LOCATION:-US}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?run: export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

echo "=== Datasets (${LOCATION}, physical storage billing) ==="
for DS in mlobs_raw mlobs_core; do
  if bq --project_id="$PROJECT_ID" show --dataset "${PROJECT_ID}:${DS}" >/dev/null 2>&1; then
    echo "  ${DS}: exists"
  else
    # PHYSICAL billing is ~5x cheaper than LOGICAL for log-shaped data and
    # cannot be changed retroactively without a 14-day wait, so set it now.
    bq --project_id="$PROJECT_ID" mk --dataset \
       --location="$LOCATION" --storage_billing_model=PHYSICAL \
       --description="ML observability platform - ${DS}" \
       "${PROJECT_ID}:${DS}"
  fi
done

echo "=== Log sink ==="
PROJECT_ID="$PROJECT_ID" bash "${HERE}/collect/create_log_sink.sh"

echo "=== Model (order matters: functions, dims, facts, views) ==="
for f in "${HERE}"/model/*.sql; do
  printf "  %-28s " "$(basename "$f")"
  if out=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false < "$f" 2>&1); then
    echo "$out" | grep -Eo '(Created|Replaced|Number of affected rows: [0-9]+) ?[a-z._-]*' \
      | tr '\n' ' '; echo
  else
    echo "FAILED"; echo "$out" | tail -5; exit 1
  fi
done

echo
echo "Done. Next:"
echo "  ${HERE}/collect/mldiag_poller.py --backfill"
echo "  ${HERE}/collect/metrics_exporter.py --hours 12"
