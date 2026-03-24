# Monitoring Guide

## Unified Dashboard

All monitoring in one page:

**[Open Dashboard](https://console.cloud.google.com/monitoring/dashboards?project=tpu-launchpad-playground)**

Dashboard includes:
- TPU utilization and HBM memory usage
- Pod CPU and memory usage
- Live training logs panel
- Pod restart count
- Quick links to Cluster Director and Logs Explorer

## View Training Logs

### Method 1: Dashboard Logs Panel

Dashboard bottom section shows live logs from all `jax-tpu` containers. No extra steps needed.

### Method 2: Logs Explorer (for search/filter)

1. Open [Logs Explorer](https://console.cloud.google.com/logs/query?project=tpu-launchpad-playground)
2. Enter query:

```
resource.type="k8s_container"
resource.labels.cluster_name="shun-elm-poc-gke"
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="YOUR_JOB_NAME"
```

Replace `YOUR_JOB_NAME` with your job's `metadata.name`.

### Useful Log Queries

```
# All logs from your job
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="alice-llama-ft-0324"

# Only training output (filter by keyword)
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="alice-llama-ft-0324"
textPayload=~"Step"

# Error logs
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="alice-llama-ft-0324"
severity>=ERROR
```

## View Training Metrics (loss, TFLOPS, MFU)

1. Open [Cluster Director Console](https://console.cloud.google.com/cluster-director?project=tpu-launchpad-playground)
2. Find your ML Run by name
3. Click **Metrics** tab to see:
   - Loss curve
   - Learning rate
   - TFLOPS / MFU
   - Step time
   - TPU/HBM utilization (auto-collected)

> Note: Metrics may take 2-5 minutes to appear after your job starts reporting.

## View Profiling

1. In Cluster Director Console, find your ML Run
2. Click **Profiles** tab
3. View:
   - **Trace Viewer** — per-TPU-core timeline of operations
   - **HLO Op Profile** — aggregated stats per operation type
   - **Graph Viewer** — HLO computation graph

### On-Demand Profiling

If your job has `on_demand_xprof=True`:
1. Go to Profiles tab
2. Click **Capture Profile**
3. Choose duration (default 2s)
4. Wait for capture to complete
