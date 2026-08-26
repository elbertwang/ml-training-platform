#!/bin/bash
# Shared plumbing for the three deploy scripts. Source it, do not execute it.
#
#   source "${HERE}/../lib/gcp.sh"
#
# Everything here is idempotent and additive. None of it deletes or replaces a
# principal's existing access -- these scripts run against a customer's
# production project, where quietly removing someone else's grant would be a
# worse failure than any permission this platform needs.

# The whole toolchain authenticates with one pre-fetched token rather than
# letting each command shell out to gcloud. On the CAA-restricted dev VM that is
# the only path that works at all; in the Cloud Run job it saves a ~1.3s fork
# per collector. Either way, one variable, checked once.
require_token() {
  : "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"
}

# ensure_service_account <project> <name> <display-name>
# Echoes the account's email either way.
ensure_service_account() {
  local project="$1" name="$2" display="$3"
  local email="${name}@${project}.iam.gserviceaccount.com"
  if ! gcloud iam service-accounts describe "$email" --project "$project" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$name" --project "$project" \
      --display-name="$display" --quiet >/dev/null
  fi
  echo "$email"
}

# grant_project_roles <project> <sa-email> <role>...
#
# Retried, because a freshly created service account is not immediately visible
# to the IAM policy API: binding a role seconds after `create` fails with
# "Service account ... does not exist". That is propagation, not an error, and
# both deploy scripts hit it on their first run.
grant_project_roles() {
  local project="$1" sa="$2"; shift 2
  local role attempt
  for role in "$@"; do
    for attempt in 1 2 3 4 5 6; do
      if gcloud projects add-iam-policy-binding "$project" \
           --member="serviceAccount:${sa}" --role="$role" \
           --condition=None --quiet >/dev/null 2>&1; then
        break
      fi
      if [[ $attempt -eq 6 ]]; then
        echo "  FAILED to grant ${role} to ${sa}" >&2
        return 1
      fi
      sleep 10
    done
  done
  echo "  granted ${*} on ${project}"
}

# grant_dataset_access <project> <sa-email> <READER|WRITER> <dataset>...
#
# Dataset-level ACL rather than IAM: `bq get-iam-policy` on a dataset needs an
# allowlist tpu-for-training does not have. The dataset resource's `access`
# array is the supported path, where READER == roles/bigquery.dataViewer and
# WRITER == dataEditor.
#
# `bq update --source` replaces the dataset configuration wholesale rather than
# merging, so this reads, modifies, writes, and then verifies that every
# pre-existing entry survived. lib/dataset_access.py aborts if one vanished.
grant_dataset_access() {
  local project="$1" sa="$2" role="$3"; shift 3
  local reader="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dataset_access.py"
  local ds before patch
  for ds in "$@"; do
    before=$(mktemp); patch=$(mktemp)
    bq --project_id="$project" show --format=prettyjson "${project}:${ds}" > "$before"
    "$reader" --mode=patch --role="$role" --before="$before" --out="$patch" --sa="$sa"
    bq --project_id="$project" update --source "$patch" "${project}:${ds}" >/dev/null
    bq --project_id="$project" show --format=prettyjson "${project}:${ds}" \
      | "$reader" --mode=verify --role="$role" --before="$before" --sa="$sa"
    rm -f "$before" "$patch"
    echo "  granted ${role} on ${ds}"
  done
}

# ensure_artifact_repo <project> <region> <repo>
ensure_artifact_repo() {
  local project="$1" region="$2" repo="$3"
  gcloud artifacts repositories describe "$repo" --location "$region" \
      --project "$project" >/dev/null 2>&1 \
    || gcloud artifacts repositories create "$repo" --repository-format=docker \
         --location="$region" --project "$project" --quiet >/dev/null
  echo "  artifact repo ${repo} ready"
}
