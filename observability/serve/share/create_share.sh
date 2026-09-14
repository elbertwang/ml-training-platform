#!/bin/bash
# Publish the consumer-facing dataset `mlobs_share` and the service account that
# reads it.
#
#   PROJECT_ID=tpu-for-training ./serve/share/create_share.sh
#
# Views, never tables. mlobs_core is refactored constantly -- columns renamed,
# grains changed, whole files rewritten -- and a consumer pinned to a table
# breaks every time. A view is the contract: the shape here changes only when we
# decide to change it, and the model underneath can move freely.
#
# Analytics Hub was the other candidate and is the wrong tool here. It shares a
# dataset into the *consumer's* project, where they run and pay for their own
# queries. Ant is using a service account in this project instead, so every
# query they run is billed to us -- which turns the design problem from access
# control into cost control. Hence:
#
#   1. views expose only what is needed, so a SELECT * cannot reach fact_event's
#      6.3 GiB by accident;
#   2. a custom BigQuery quota caps the service account's daily bytes. This is
#      the only *enforced* control and it is a manual step -- do not hand over
#      credentials before setting it.
#
# require_partition_filter was the obvious third control and cannot be used:
# our own model reads these tables unfiltered in three places (08_views.sql
# lines 25 and 42 over fact_event, 09_fin_utilization.sql lines 321 and 340 over
# fact_step), so turning it on would break the refresh before it ever inconve-
# nienced a consumer. The documentation tells consumers to filter; the quota is
# what happens when they do not.
#
# Measured before choosing this: one unbounded SELECT * on fact_event polled
# every minute is 9 TiB/day, about $1,700/month. The same poll with a one-minute
# watermark predicate is ~220 MB.
set -euo pipefail

# shellcheck source=../../lib/gcp.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/gcp.sh"

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
LOCATION="${LOCATION:-US}"
SHARE="${SHARE:-mlobs_share}"
SA_NAME="${SA_NAME:-mlobs-share-reader}"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

bqq() { bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --quiet --format=none "$@"; }

echo "=== dataset ==="
if bq --project_id="$PROJECT_ID" show "$SHARE" >/dev/null 2>&1; then
  echo "  ${SHARE} exists"
else
  bq --project_id="$PROJECT_ID" mk --dataset --location="$LOCATION" \
     --description="Consumer-facing views over the ML observability model. Views only; see serve/share/create_share.sh." \
     "${PROJECT_ID}:${SHARE}" >/dev/null
  echo "  ${SHARE} created"
fi

echo "=== views ==="

# ---------------------------------------------------------------------------
# Freshness first, because every other view is useless without it.
#
# The model refreshes every 30 minutes and the collectors reach back an hour, so
# "now" in this dataset is 15-30 minutes ago and each table lags differently.
# A consumer that builds a five-minute alert on a 25-minute-old table will fire
# late and blame the platform. Publishing the lag makes that unmissable.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_freshness AS
SELECT 'chip_hourly' AS table_name, MAX(hour) AS newest,
       TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(hour), SECOND) AS lag_seconds
FROM mlobs_core.chip_hourly
UNION ALL SELECT 'fact_event', MAX(event_time),
       TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(event_time), SECOND)
FROM mlobs_core.fact_event
UNION ALL SELECT 'fact_step', MAX(step_time),
       TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(step_time), SECOND)
FROM mlobs_core.fact_step
UNION ALL SELECT 'job', MAX(last_seen),
       TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(last_seen), SECOND)
FROM mlobs_core.job_hub
UNION ALL SELECT 'fin_daily', TIMESTAMP(MAX(day)),
       TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), TIMESTAMP(MAX(day)), SECOND)
FROM mlobs_core.fin_daily"
echo "  v_freshness"

# ---------------------------------------------------------------------------
# The wide table: one row per chip per hour.
#
# Numerator and denominator both present. vm_slots counts the five-minute slots
# in which the chip's node was up -- the node-scoped accelerator metrics report
# for a chip whether or not a pod is on it -- and pod_slots counts those where a
# job held it. So the two in-VM ratios are computable from this table alone.
#
# Paid capacity is the exception and is deliberately absent: a reserved chip
# with no VM emits no series of any kind, so it cannot have a row keyed on a
# chip. v_capacity_daily carries that denominator per reservation, joined on
# reservation_name.
#
# 12k rows a day. A full read of a month is cheap; no partition predicate is
# required, though one still prunes.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_chip_hourly AS
SELECT
  hour, chip_id, instance_id, chip_index,
  node_name, cluster_name, location,
  node_pool, capacity_class, reservation_name, machine_type, tpu_topology,
  pod_name, job_key, job_family,
  vm_slots, pod_slots,
  duty_pct, tensorcore_pct, membw_pct,
  vm_chip_hours, pod_chip_hours, duty_chip_hours, busy_chip_hours, membw_chip_hours
FROM mlobs_core.chip_hourly"
echo "  v_chip_hourly"

# The paid side, per reservation per day. reservation_name is carried so the
# wide table joins to it without a bridge.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_capacity_daily AS
SELECT
  c.day, c.reservation_id, r.reservation_name, c.location,
  c.paid_chip_hours, c.scheduled_chip_hours, c.avg_reserved_chips, c.day_coverage
FROM mlobs_core.fin_capacity_daily c
LEFT JOIN (
  SELECT reservation_id, ANY_VALUE(reservation_name) AS reservation_name
  FROM mlobs_raw.reservation_snapshot GROUP BY reservation_id
) r USING (reservation_id)"
echo "  v_capacity_daily"

# Daily, already gated. Ratios here are NULL when their coverage test failed --
# see day_coverage / work_coverage / metric_coverage, which travel with the row
# so a consumer can re-apply or relax the rule.
#
# Columns listed explicitly, never SELECT *. Two reasons, and the second is the
# one that bites: a SELECT * share view silently republishes whatever the model
# grows next, so a column added for internal use becomes a customer contract
# without anyone deciding it should.
#
# The first reason is that fin_daily carries money -- paid_usd, idle_usd and
# rate_usd_per_chip_hour -- and those are deliberately withheld. Rates are
# commercial terms and were removed from this repository for that reason;
# idle_usd was also removed from our own dashboard because it reads as "this
# share of spend was wasted" when the honest statement is "this share could not
# be attributed". Sending it to a data team that will never see the dashboard's
# caveats reintroduces exactly that failure. Add them back deliberately if the
# customer asks, not by default.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_utilization_daily AS
SELECT
  day,
  paid_chip_hours, scheduled_chip_hours, pod_chip_hours,
  duty_chip_hours, busy_chip_hours, flops_chip_hours, stepping_chip_hours,
  reservation_utilization_pct, chip_utilization_pct, mfu_pct,
  global_allocate_rate, global_tpu_utils,
  tpu_allocate_rate_in_vm, tpu_utils_in_vm,
  vm_chip_hours, membw_chip_hours, chips_seen, nodes_seen,
  day_coverage, work_coverage, metric_coverage, funnel_monotonic
FROM mlobs_core.fin_daily"
echo "  v_utilization_daily"

# Long format: one row per (day, metric), each carrying its own formula string.
# Built for loading into a system that stores metrics generically rather than as
# columns.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_metric_export AS
SELECT * FROM mlobs_core.fin_export
WHERE metric NOT IN ('paid_usd', 'idle_usd')"
echo "  v_metric_export"

# Jobs. 23k rows and 19 MiB, so no partition filter is needed; the deep links
# are included because they are the reason a reader opens this at all.
# owner carries the submitter's address verbatim, by decision.
#
# The column holds real addresses with @ rewritten to - : personal QQ, Gmail and
# university accounts alongside company ones at primatrix.ai and
# infiscale-tech.com. It was pseudonymised for a while and that was reverted on
# request -- the consumer needs to reach the person behind a job, and a hash
# cannot do that. Recorded here so it reads as a choice rather than an oversight
# the next time someone reviews what leaves this dataset.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_job AS
SELECT
  h.job_key, h.job_family, h.cluster_name, h.namespace_name, h.owner,
  h.first_seen, h.last_seen, h.attempts, h.peak_chips, h.peak_nodes,
  h.tpu_model, h.chip_hours, h.goodput_pct,
  a.run_name, a.tensorboard_gs, a.tensorboard_url
FROM mlobs_core.job_hub h
LEFT JOIN mlobs_core.dim_job_artifact a USING (job_key)"
echo "  v_job"

# Explicit columns for the same contract-drift reason as v_utilization_daily.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_incident AS
SELECT incident_uid, kind, category, title, target_kind, target,
       cluster_name, state, reason, window_start, window_end, affected_jobs
FROM mlobs_core.fact_incident"
echo "  v_incident"

# ---------------------------------------------------------------------------
# The two big ones. Both are partitioned and both are published through a view
# that carries the partition column, so a watermark predicate prunes.
bqq "CREATE OR REPLACE VIEW ${SHARE}.v_event AS
SELECT event_time, job_key, attempt_uid, cluster_name, namespace_name,
       source, severity, event_type, summary, pod_name, node_name
FROM mlobs_core.fact_event"
echo "  v_event"

bqq "CREATE OR REPLACE VIEW ${SHARE}.v_step AS
SELECT step_time, job_key, attempt_uid, job_family, step,
       loss, grad_norm, nan_iters, skipped_iters,
       step_seconds_p50, straggler_ratio, tflops_p50, ranks_reporting
FROM mlobs_core.fact_step"
echo "  v_step"

echo "=== service account ==="
if gcloud iam service-accounts describe "$SA" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "  ${SA} exists"
else
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT_ID" \
    --display-name="ML observability share reader (Ant)" >/dev/null
  echo "  ${SA} created"
fi

# jobUser at project level is unavoidable -- running any query needs it -- and is
# what makes the custom quota below the real control rather than a nicety.
#
# Both grants go through lib/gcp.sh, which retries: a service account is not
# visible to the IAM policy API for several seconds after creation, and binding
# immediately fails with "Service account ... does not exist". This script hit
# exactly that on its first run.
grant_project_roles "$PROJECT_ID" "$SA" roles/bigquery.jobUser

# READER on the share dataset ONLY. The views read mlobs_core, which this
# account cannot touch directly; the authorization below is what bridges that.
grant_dataset_access "$PROJECT_ID" "$SA" READER "$SHARE"

# Authorized views: mlobs_core trusts the views in mlobs_share, so the reader
# needs no access to the underlying tables. This is what keeps raw staging
# (mlobs_raw, 62 GiB) and un-gated intermediates out of reach.
python3 - "$PROJECT_ID" "$SHARE" <<'PY'
import json, subprocess, sys
project, share = sys.argv[1], sys.argv[2]
views = subprocess.run(["bq", f"--project_id={project}", "ls", "--format=json", "-n", "500", share],
                       capture_output=True, text=True).stdout
names = [v["tableReference"]["tableId"] for v in json.loads(views or "[]")]
cur = json.loads(subprocess.run(["bq", f"--project_id={project}", "show", "--format=prettyjson", "mlobs_core"],
                                capture_output=True, text=True).stdout)
acc = cur.setdefault("access", [])
added = 0
for n in names:
    entry = {"view": {"projectId": project, "datasetId": share, "tableId": n}}
    if entry not in acc:
        acc.append(entry); added += 1
if added:
    import tempfile, os
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump({"access": acc}, fh); path = fh.name
    subprocess.run(["bq", f"--project_id={project}", "update", "--source", path, "mlobs_core"],
                   capture_output=True, text=True)
    os.unlink(path)
print(f"  authorized {added} view(s) against mlobs_core ({len(names)} total)")
PY

echo "=== smoke check ==="
# Creating a view only validates its SQL against the schema of the moment. A
# column removed from the model later leaves the view compiling and failing at
# query time, which is how v_utilization_daily stayed broken for three days
# after fin_work_daily dropped two columns. Every view is queried here so the
# deploy fails instead of the consumer.
SMOKE_FAIL=0
for V in $(bq --project_id="$PROJECT_ID" ls --format=json -n 500 "$SHARE" \
           | python3 -c "import json,sys;print(' '.join(v['tableReference']['tableId'] for v in json.load(sys.stdin)))"); do
  if bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --quiet --format=none \
       "SELECT 1 FROM \`${PROJECT_ID}.${SHARE}.${V}\` LIMIT 1" >/dev/null 2>&1; then
    echo "  ${V} ok"
  else
    echo "  ${V} FAILS TO QUERY" >&2
    SMOKE_FAIL=1
  fi
done
[[ $SMOKE_FAIL -eq 0 ]] || { echo "  one or more share views are unqueryable" >&2; exit 1; }

cat <<EOF

=== still to do by hand ===

  1. Cap the spend. IAM stops the account reading the wrong data; it does not
     stop it reading the right data too often. Set a custom quota so a runaway
     poll fails instead of billing:

       Console > IAM & Admin > Quotas > BigQuery API
         "Query usage per day per user"  ->  set an override for
         ${SA}
       A starting point: 200 GiB/day. The intended access pattern -- the
       5-minute view in full plus watermarked reads of v_event and v_step --
       lands under 5 GiB/day, so 200 leaves room for backfills while stopping
       the 9 TiB/day unbounded-poll case.

  2. Hand over credentials. Prefer workload identity federation if Ant runs on
     a cloud we can federate with; a downloaded key is a long-lived secret with
     no expiry and should be the fallback, not the default:

       gcloud iam service-accounts keys create ant-reader.json \\
         --iam-account=${SA} --project=${PROJECT_ID}

  3. Send them docs/ant-data-access.md.
EOF
