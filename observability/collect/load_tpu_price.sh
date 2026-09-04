#!/bin/bash
# Load the TPU rate card into mlobs_core.dim_tpu_price from a CSV held outside
# this repository.
#
#   TPU_PRICE_CSV=gs://<bucket>/<path>.csv PROJECT_ID=<project> ./load_tpu_price.sh
#
# Rates are commercial terms, so they live in a bucket the finance owner
# controls rather than in git, in the mirror under primatrix/maxtext, or in a
# pull request. This script is the only thing that moves them, and it carries no
# numbers itself.
#
# CSV columns, no header:
#   tpu_model,usage_type,usd_per_chip_hour
#
# tpu_model must be the GKE accelerator name, not the marketing name -- see the
# comment block in model/05_dim_tpu_price.sql, which is also where usage_type
# and the per-chip unit are explained.
#
# WRITE_TRUNCATE, so the file is the whole card and removing a row removes the
# rate. Anything the model cannot find a rate for produces NULL currency rather
# than a wrong number, which is the intended failure.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
DATASET="${DATASET:-mlobs_core}"
TPU_PRICE_CSV="${TPU_PRICE_CSV:?TPU_PRICE_CSV must be set, e.g. gs://bucket/tpu_rates.csv}"

echo "  loading rate card from ${TPU_PRICE_CSV}"
bq --project_id="$PROJECT_ID" load \
  --source_format=CSV \
  --replace \
  "${DATASET}.dim_tpu_price" "$TPU_PRICE_CSV" \
  "tpu_model:STRING,usage_type:STRING,usd_per_chip_hour:FLOAT" >/dev/null

# Report shape, never values -- this script's whole point is that the numbers
# do not appear anywhere a reader of the repo or of CI logs can see them.
bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
  "SELECT CONCAT('  loaded ', CAST(COUNT(*) AS STRING), ' rates over ',
                 CAST(COUNT(DISTINCT tpu_model) AS STRING), ' chip models')
   FROM \`${PROJECT_ID}.${DATASET}.dim_tpu_price\`" | tail -1
