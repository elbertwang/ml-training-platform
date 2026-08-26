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

# Refuse to run alongside another execution of the same job.
#
# Cloud Scheduler fires on the clock regardless of whether the previous run
# finished, and Cloud Run jobs happily run executions concurrently. On
# 2026-08-26 two overlapped for two minutes; the model's window swaps are now
# transactional so that cannot corrupt anything, but two concurrent writers
# would just make one of them fail on serialisation. Skipping is the right
# answer: the next tick is 30 minutes away and every step is idempotent.
#
# Exits 0, not 1 -- a skipped run is normal operation, not a failure, and
# should not page anyone.
if [[ -n "${CLOUD_RUN_EXECUTION:-}" && -n "${CLOUD_RUN_JOB:-}" ]]; then
  # Deliberately verbose. The first two versions of this guard silently did
  # nothing -- once because the API call failed and `curl -sf` swallowed it,
  # once because the filter was inverted -- and in both cases the log looked
  # identical to a clean run. Print what was seen so a future failure is
  # visible instead of silent.
  EXEC_JSON=$(curl -s -w '\n%{http_code}' \
    -H "Authorization: Bearer ${CLOUDSDK_AUTH_ACCESS_TOKEN}" \
    "https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION:-us-central1}/jobs/${CLOUD_RUN_JOB}/executions?pageSize=20" \
    || true)
  HTTP_CODE=$(tail -1 <<<"$EXEC_JSON")
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "overlap check: executions API returned ${HTTP_CODE}, proceeding anyway"
  else
    RUNNING=$(sed '$d' <<<"$EXEC_JSON" | python3 -c '
import json, os, sys
me = os.environ["CLOUD_RUN_EXECUTION"]
execs = json.load(sys.stdin).get("executions", [])
# A missing completionTime is the only signal that an execution is still
# going. Do NOT also require `reconciling` to be false: reconciling is True
# precisely while a run is in flight, so filtering on it excludes the very
# executions this check exists to find. That inversion is why an earlier
# version of this guard never fired.
print(" ".join(e["name"].rsplit("/", 1)[-1] for e in execs
                if e["name"].rsplit("/", 1)[-1] != me
                and not e.get("completionTime")))')
    echo "overlap check: me=${CLOUD_RUN_EXECUTION} others_running=[${RUNNING}]"
    if [[ -n "${RUNNING// /}" ]]; then
      # Exit 0, not 1 -- a skipped run is normal operation, not a failure, and
      # should not page anyone. The next tick is 30 minutes away and every
      # step is idempotent.
      echo "skip: another execution is already running"
      exit 0
    fi
  fi
fi

echo "refresh start $(date -u +%FT%TZ) project=${PROJECT_ID}"
exec /app/refresh.sh
