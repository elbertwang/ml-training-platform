#!/bin/bash
# Cloud Run job entrypoint: get one token, then hand off to refresh.sh.
#
# Everything downstream reads CLOUDSDK_AUTH_ACCESS_TOKEN -- a habit that started
# as a workaround for a CAA-restricted dev VM, but which happens to be the right
# shape here too: one metadata-server call per run instead of a ~1.3s `gcloud
# auth` fork per collector.
#
# The token is valid for an hour. If a refresh ever runs longer than that this
# needs re-fetching mid-run, so the job's task timeout is deliberately set below
# an hour in deploy.sh.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"

CLOUDSDK_AUTH_ACCESS_TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
export CLOUDSDK_AUTH_ACCESS_TOKEN

# bq writes a ~/.bigqueryrc and a credential cache; Cloud Run's filesystem is
# writable but the HOME the container inherits may not be, so pin it to /tmp.
export HOME=/tmp
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

echo "refresh start $(date -u +%FT%TZ) project=${PROJECT_ID}"
exec /app/refresh.sh
