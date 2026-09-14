#!/bin/bash
# Backfill `completed step` log lines from the Log Analytics linked dataset into
# mlobs_raw.step_lines_backfill, so fact_step -- and therefore MFU -- can reach
# back before the sink existed.
#
#   DAYS=30 PROJECT_ID=tpu-for-training ./backfill_step_lines.sh
#
# A sink is not retroactive. fact_step is built from the sink's stdout/stderr
# tables, which start when the sink was created, so MFU has no history before
# that date however much metric data is loaded. defaultLink still holds whatever
# the _Default bucket retains -- 30 days here -- and this lifts the step lines
# out of it.
#
# Only three fields are taken, because that is all fact_step reads: the
# timestamp, the pod name, and the message. Everything else v_sink_logs exposes
# is left NULL rather than reconstructed, which keeps the scan to the columns
# that matter.
#
# **One query per day, not one over the window.** The full 30-day scan is
# ~16 TB; as a single statement a failure at hour 700 discards all of it, and
# there is no way to see how far it got. Per day it is ~530 GB, each day is
# committed on its own, and re-running skips days already present.
#
# COST: this scan is expensive and the price is per run. Measured 2026-09-04 over
# 31 days: 10.74 TiB billed, about $67 at the US on-demand rate. The output is
# persisted in mlobs_raw.step_lines_backfill and days already present are
# skipped, so a re-run is nearly free -- but widening DAYS, or dropping the
# table first, pays the full amount again. Check what is already there before
# reaching for this.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
DAYS="${DAYS:-30}"
TABLE="mlobs_raw.step_lines_backfill"

bqq() { bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --quiet --format=none "$@"; }

# DATE-partitioned so a re-run can delete and rewrite one day without touching
# the rest, and so fact_step's window prunes when it reads through v_sink_logs.
bqq "CREATE TABLE IF NOT EXISTS ${TABLE}
     (timestamp TIMESTAMP, resource JSON, text_payload STRING, json_payload JSON)
     PARTITION BY DATE(timestamp)"

# Anchored to a fixed date, computed once. `date -u -d "$i days ago"` inside the
# loop is relative to the moment it runs, so two runs a few hours apart covered
# different ranges and today was never covered by either -- the loop stops at
# i=1, which is yesterday. END_DAY defaults to today so the current partial day
# is included; set it to pin a historical window.
END_DAY="${END_DAY:-$(date -u +%Y-%m-%d)}"
for ((i = DAYS; i >= 0; i--)); do
  DAY=$(date -u -d "${END_DAY} -${i} days" +%Y-%m-%d)
  NEXT=$(date -u -d "${DAY} +1 day" +%Y-%m-%d)

  # "Any rows at all" is not the same as "this day is done". An INSERT that
  # committed part-way, or an earlier run with a narrower window, leaves rows
  # behind and this skip then makes the shortfall permanent -- fact_step and
  # MFU are quietly light for that day with nothing to notice. SKIP_PARTIAL=0
  # re-reads a day that already has rows; the load is idempotent per day
  # because the DELETE below clears the date first.
  HAVE=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
         "SELECT COUNT(*) FROM ${TABLE} WHERE DATE(timestamp) = '${DAY}'" | tail -1)
  if [[ "${HAVE:-0}" -gt 0 && "${SKIP_PARTIAL:-1}" == "1" ]]; then
    echo "  ${DAY}: ${HAVE} rows already, skipping (SKIP_PARTIAL=0 to re-read)"
    continue
  fi

  # Clear the day first. This used to be a bare INSERT, which made the skip
  # above load-bearing: without it a second pass over a day silently doubled its
  # rows. Deleting the date makes one day one unit of work, so re-reading a
  # partial day is a repair rather than a corruption.
  bqq "DELETE FROM ${TABLE} WHERE DATE(timestamp) = '${DAY}'" >/dev/null

  # resource is rebuilt as JSON with only labels.pod_name, which is the single
  # field fact_step reads out of it. TO_JSON of the whole struct would carry
  # every label on every line and multiply the stored size for no reader.
  bqq "INSERT INTO ${TABLE} (timestamp, resource, text_payload, json_payload)
       SELECT
         timestamp,
         TO_JSON(STRUCT(STRUCT(resource.labels.pod_name AS pod_name) AS labels)),
         text_payload,
         json_payload
       FROM \`${PROJECT_ID}.defaultLink._AllLogs\`
       WHERE timestamp >= TIMESTAMP('${DAY}') AND timestamp < TIMESTAMP('${NEXT}')
         AND log_id IN ('stdout', 'stderr')
         AND COALESCE(text_payload, JSON_VALUE(json_payload, '\$.message'))
             LIKE '%completed step%'"

  N=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
      "SELECT COUNT(*) FROM ${TABLE} WHERE DATE(timestamp) = '${DAY}'" | tail -1)
  echo "  ${DAY}: ${N} rows"
done

echo "  done. Rebuild v_sink_logs so the new table is picked up, then run"
echo "  model/07_fact_step.sql with a widened step_window_start."
