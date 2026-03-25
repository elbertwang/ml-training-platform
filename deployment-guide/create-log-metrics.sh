#!/bin/bash
# Create log-based metrics for ML training metrics
# These extract actual values from MLDiagnostics Cloud Logging entries
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tpu-launchpad-playground}"

echo "=== Creating Log-based Metrics ==="

# Define metrics: name|namespace|description
METRICS=(
  "ml_training_loss|loss|Training Loss"
  "ml_training_step_time|step_time|Step Time (seconds)"
  "ml_training_tflops|tflops|TFLOPS"
  "ml_training_mfu|mfu|Model FLOPS Utilization"
  "ml_training_learning_rate|learning_rate|Learning Rate"
  "ml_training_gradient_norm|gradient_norm|Gradient Norm"
  "ml_training_throughput|throughput|Throughput"
)

for entry in "${METRICS[@]}"; do
  IFS='|' read -r name namespace description <<< "$entry"
  echo "Creating: $name (namespace=$namespace)"

  cat > /tmp/metric_config.json << MEOF
{
  "name": "$name",
  "description": "$description",
  "filter": "logName=\"projects/$PROJECT_ID/logs/ml_diagnostics_metric\" AND resource.labels.namespace=\"$namespace\"",
  "valueExtractor": "EXTRACT(jsonPayload.values)",
  "labelExtractors": {
    "job_name": "EXTRACT(resource.labels.node_id)"
  },
  "metricDescriptor": {
    "metricKind": "DELTA",
    "valueType": "DISTRIBUTION",
    "labels": [
      {
        "key": "job_name",
        "description": "ML Run / Job identifier"
      }
    ]
  },
  "bucketOptions": {
    "explicitBuckets": {
      "bounds": [0, 0.0001, 0.001, 0.01, 0.1, 0.5, 1, 2, 5, 10, 50, 100, 500, 1000, 5000]
    }
  }
}
MEOF

  gcloud logging metrics create "$name" \
    --config-from-file=/tmp/metric_config.json \
    --project="$PROJECT_ID" 2>/dev/null \
    && echo "  Created." \
    || echo "  Already exists or error (skipping)."
done

echo ""
echo "=== Done ==="
echo "Metrics appear as: logging.googleapis.com/user/<name>"
echo "Note: Only NEW log entries after creation will be counted."
