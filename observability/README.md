# ML Observability Platform — MVP

An aggregated monitoring and analysis layer for TPU training on GKE, built on
GCP-native services. It exists to answer three questions that no single existing
console answers today:

1. **Why did this job get slow / hang / die?** — one timeline, all sources.
2. **How much of our TPU time is actually productive, and what does the waste
   cost?** — Goodput and cost per job.
3. **Where do I look?** — one entry point instead of 11 dashboards and 4 consoles.

Target environment: project `tpu-for-training`, clusters `tpu-training-antgroup`
(143 nodes) and `tpu-training-antgroup-v2`, region `us-central1`.

---

## What the MVP proved

A real incident, reconstructed end-to-end by `v_incident_timeline`
(job `falcon-job-jaytje07es`, 2026-08-24):

```
03:37   64 pods start; gke-gcsfuse-sidecar containers created
03:42   LOG STORM  152,717,258 lines in 5 min across 64 pods (~1.6M per pod)
03:47   LOG STORM  155,546,110 lines in 5 min
03:52   ML Diagnostics opens PERFORMANCE_DEGRADATION -- 9 analyzers, none detected
03:52 ─────────── 256 TPU7x chips at 0.0% tensorcore, continuously ─────────── 05:37
05:09   falcon-agent heartbeat failures
05:35   containers stopped
```

256 chips idle for 1h45m. ML Diagnostics detected the degradation but every one
of its nine analyzers returned NOT_DETECTED, so on its own it could not name a
cause. Putting the log-rate metric on the same timeline makes the cause obvious.

Cluster-wide over the same 12-hour window (89 jobs, 5,507 chip-hours):

| Goodput bucket | Jobs | chip-hours |
|---|---|---|
| 0% (fully idle)| 25 | 593 |
| 0–25%          |  7 | 1,424 |
| 25–50%         | 10 | 815 |
| 50–75%         | 16 | 315 |
| 75–100%        | 31 | 2,361 |

Cluster goodput: **52.3%**. See "Caveats" before quoting the dollar figures.

---

## Architecture

```
                        ┌──────────────── collect ────────────────┐
GKE pods / nodes ──logs──▶ Cloud Logging _Default (30d, US)
                          ├─▶ Log Analytics + defaultLink  ← full fidelity, $0 extra
                          └─▶ sink `mlobs-selective` ──────▶ mlobs_raw.<log_id>
ML Diagnostics REST ───────▶ mldiag_poller.py ─────────────▶ mlobs_raw.mldiag_*
Cloud Monitoring ──────────▶ metrics_exporter.py ──────────▶ mlobs_raw.metric_samples
                        └──────────────────────────────────────────┘
                                              │
                        ┌──────── model (plain SQL, US) ───────────┐
                        │ dim_mlrun  dim_tpu_price                 │
                        │ fact_mlrun_event  fact_event  fact_goodput│
                        │ v_job_timeline  v_incident_timeline       │
                        │ v_job_error_burst                         │
                        └──────────────────────────────────────────┘
```

### Why the data lands where it does

The single most important constraint is measured, not assumed. In this project
Cloud Logging ingests **1,631 GiB/day** (14-day mean of
`logging.googleapis.com/billing/bytes_ingested`), ~1.24B entries, of which
`k8s_container` is 99.6%. Mean billed size is ~1.4 KB/entry — the payload is
only ~273 bytes, so **labels and metadata are ~80% of the bill**.

Querying that through the `defaultLink` linked dataset costs, per day of data:

| What the query touches | Bytes scanned |
|---|---|
| `timestamp` only | 9.9 GB |
| `+ severity` | 20 GB |
| `+ resource` | 174 GB |
| `+ json_payload` | 245 GB |
| `+ labels` | **303 GB** |
| `log_id='events'` + labels | **10.5 GB** |
| `severity>=ERROR` + payload | **11.9 GB** |

So `log_id` and `severity` prune hard and everything else does not. The model
layer therefore **never scans the unfiltered payload**: it reads the two
prunable slices from the linked dataset, and gets everything else from the
selective sink or from metrics.

Signal density makes the same point: of 624M `falcon-jobs` log lines in six
hours, 7,854 contained "loss" and 1,654 contained "tflop"/"mfu" — **0.0013%**.

### Three collection paths, and why each exists

| Path | Carries | Why not one of the others |
|---|---|---|
| `defaultLink` (Log Analytics) | everything, 30 days | free and full-fidelity, but expensive to scan repeatedly and capped at bucket retention |
| sink `mlobs-selective` | ERROR+, `completed step`, k8s events, autoscaler, TPU runtime, mldiag events, audit | permanent retention and cheap repeated queries; ~1.8M rows/day |
| `metrics_exporter.py` | TPU utilisation, HBM, log rate, interruptions | these are metrics, not logs. `log_entry_count` in particular detects log storms for free — finding the same thing in logs would mean scanning the WARNING tier, which is 75% of all volume |
| `mldiag_poller.py` | ML runs, monitored events, analyzer verdicts | REST-only; `gcloud` has no `mldiagnostics` command group |

`severity=WARNING` is deliberately **not** sinked: 932M rows on 2026-08-24,
almost entirely the two gcsfuse log storms.

---

## Layout

```
collect/
  mldiag_poller.py      ML Diagnostics REST -> mlobs_raw.mldiag_{runs,events}
  metrics_exporter.py   Cloud Monitoring    -> mlobs_raw.metric_samples
  create_log_sink.sh    selective Log Router sink -> mlobs_raw
model/
  00_functions.sql      api_ts(), job_key_from_pod()
  01_dim_mlrun.sql      one row per ML Diagnostics run
  02_fact_mlrun_event.sql  monitored events + flattened analyzer verdicts
  03_fact_event.sql     unified event stream (mldiag + k8s events + app errors)
  04_job_timeline.sql   v_job_timeline, v_job_error_burst
  05_fact_goodput.sql   per-job chip-hours, goodput ratio, cost
  06_dim_tpu_price.sql  TPU rate card
  07_v_incident_timeline.sql  timeline + log-rate + tpu-idle signals
deploy.sh               create datasets, apply model in order
```

## Running it

```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

./deploy.sh                                     # datasets + sink + all model SQL
collect/mldiag_poller.py --backfill             # ~13.4k runs, ~4.1k events, ~4 min
collect/metrics_exporter.py --hours 12          # ~460k points, ~6 min

# then, on a schedule:
collect/mldiag_poller.py --since-hours 6        # incremental
collect/metrics_exporter.py --hours 1
bq query --use_legacy_sql=false < model/03_fact_event.sql   # rebuild the window
```

Nothing here modifies existing logging, monitoring or cluster configuration. The
sink only adds a BigQuery destination; ingestion, the `_Default` bucket, the 11
existing dashboards and the 7 existing alert policies are untouched.

---

## Caveats — read before quoting any number

- **TPU price unit is unverified.** The Cloud Billing Catalog SKU "TPU7x running
  in Americas" is `$12.00/hour` but does not state chip or host. We assume
  per-chip-hour (consistent with the v6e SKU matching its published per-chip
  price). A `tpu7x-standard-4t` host holds 4 chips, so if the SKU is per host
  every dollar figure is **4x too high**. There is no Cloud Billing BigQuery
  export in this project to reconcile against.
- **List price only.** No committed-use or reservation discount is applied.
- **Goodput is a proxy.** It measures "chips above 10% tensorcore, averaged over
  5-minute buckets", not whether the training was useful. A diverging run at
  100% tensorcore scores as perfect goodput.
- **12-hour sample.** The cluster-wide figures come from one 12-hour window on
  2026-08-24. Log volume in this project varies 2x day to day.
- **ML Diagnostics history is ~2 months**, not 5: of 13,400 runs, only 3 predate
  2026-07-01. Monitored events appear to age out faster still.

## Known gaps (not in the MVP)

- Not yet collected: GKE Operations API, K8s Job/Kueue object snapshots,
  serial-console output, checkpoint I/O timings, XProf artifact index.
- `fact_event` is rebuilt over a rolling window by hand; no scheduler yet.
- No Dataform, no Cloud Run deployment, no dashboards or alert policies yet.
- `tpu.googleapis.com/instance/interruption_count` returned zero points in the
  sampled window — collection is wired up but unproven.
- The `maxtext_completed_step` log-based metric filters on
  `pod_name=~"-worker-"`, which matches the `default`-namespace MaxText family
  but **not** `falcon-jobs` pods (`falcon-job-<id>-<idx>-<hash>`). The
  "Training Stalled (No Step for 20min)" alert therefore does not cover falcon
  jobs. Not fixed here — it is a change to an existing production alert.
