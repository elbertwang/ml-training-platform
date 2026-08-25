#!/bin/bash
# List (and optionally delete) the abandoned custom metric descriptors that
# predate this platform.
#
#   PROJECT_ID=tpu-for-training ./deprecate_legacy_metrics.sh          # dry run
#   PROJECT_ID=tpu-for-training APPLY=true ./deprecate_legacy_metrics.sh
#
# READ THIS BEFORE RUNNING WITH APPLY=true
#
# Deleting these saves nothing. Cloud Monitoring bills Metric Volume on bytes
# *ingested*; a descriptor with no writer costs $0 whether it exists or not. The
# only benefit is that Metrics Explorer stops offering 771 dead options. Deletion
# is irreversible and takes the historical data with it, so if anyone might still
# want to look at what MFU was in July, do not run this.
#
# What is actually worth doing is absorbing the capabilities -- see
# README section 12. In short:
#   maxtext/perf_mfu, perf_step_time_seconds, learning_loss  -> fact_step, from
#       the `completed step` log lines that are already in the sink. The lines
#       also carry `Config param peak_tflops_per_device`, which is the
#       denominator MFU needs.
#   tpu_finance/month_reservation_utilization -> genuinely missing. Needs
#       reservation capacity from the Compute API, which no current source has.
#   training/autorepair_downtime_seconds, autorepair_rollback_steps -> derivable
#       from dim_job_attempt plus the node/pod events already in fact_event.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
APPLY="${APPLY:-false}"
PREFIXES="${PREFIXES:-maxtext/ tpu_finance/ ling3/ training/}"

: "${CLOUDSDK_AUTH_ACCESS_TOKEN:?export CLOUDSDK_AUTH_ACCESS_TOKEN=\$(gcloud auth application-default print-access-token)}"

TOKEN="$CLOUDSDK_AUTH_ACCESS_TOKEN"
API="https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}"

for PFX in $PREFIXES; do
  echo "=== custom.googleapis.com/${PFX} ==="
  NAMES=$(curl -s -G -H "Authorization: Bearer $TOKEN" "${API}/metricDescriptors" \
    --data-urlencode "filter=metric.type=starts_with(\"custom.googleapis.com/${PFX}\")" \
    --data-urlencode "pageSize=2000" \
    | python3 -c 'import sys,json;[print(d["name"]) for d in json.load(sys.stdin).get("metricDescriptors",[])]')
  COUNT=$(wc -l <<<"$NAMES"); [[ -z "$NAMES" ]] && COUNT=0
  echo "  ${COUNT} descriptors"
  [[ "$COUNT" -eq 0 ]] && continue

  # Only offer to delete what has genuinely stopped being written.
  SAMPLE=$(head -1 <<<"$NAMES" | sed 's|.*/metricDescriptors/||')
  RECENT=$(curl -s -G -H "Authorization: Bearer $TOKEN" "${API}/timeSeries" \
    --data-urlencode "filter=metric.type=\"${SAMPLE}\"" \
    --data-urlencode "interval.startTime=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode 'aggregation.alignmentPeriod=86400s' \
    --data-urlencode 'aggregation.perSeriesAligner=ALIGN_MEAN' \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("timeSeries",[])))')
  if [[ "$RECENT" != "0" ]]; then
    echo "  STILL WRITTEN (sample ${SAMPLE} has data in the last 7d) -- skipping"
    continue
  fi
  echo "  no data in 7d for sample ${SAMPLE}"

  if [[ "$APPLY" != "true" ]]; then
    echo "  dry run; set APPLY=true to delete"
    continue
  fi
  while read -r N; do
    [[ -z "$N" ]] && continue
    curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
      "https://monitoring.googleapis.com/v3/${N}" >/dev/null
  done <<<"$NAMES"
  echo "  deleted ${COUNT}"
done
