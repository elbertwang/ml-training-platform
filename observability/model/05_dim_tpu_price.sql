-- dim_tpu_price: TPU rate card, joined to fact_goodput to turn chip-hours into
-- money. A table rather than a hard-coded CASE so it can be corrected without a
-- model change.
--
-- `tpu_model` must match the `model` metric label on
-- kubernetes.io/container/accelerator/* exactly. Those values are GKE
-- accelerator names, not the marketing names used in the price list -- observed
-- values are `tpu7x`, `tpu-v5-lite-podslice`, `tpu-v6e-slice`, `tpu-v5p-slice`.
-- A first version keyed on 'v6e'/'v5p' and silently joined to nothing, leaving
-- every cost column NULL.
--
-- On-demand list prices from the Cloud Billing Catalog API, us-central1,
-- 2026-08-24.
--
-- !! VERIFY BEFORE TRUSTING ANY COST COLUMN !!
-- The SKU reads "TPU7x running in Americas ... usageUnit: h" and does not say
-- whether the hour is per chip or per host. We assume per chip-hour, consistent
-- with the v6e SKU ($2.70/h) matching its published per-chip price. A
-- tpu7x-standard-4t host carries 4 chips, so if the SKU is per host then every
-- cost figure is 4x too high. Neither project has a Cloud Billing BigQuery
-- export to reconcile against -- creating one is the fix.

CREATE OR REPLACE TABLE mlobs_core.dim_tpu_price AS
SELECT * FROM UNNEST([
  STRUCT('tpu7x'                AS tpu_model, 'OnDemand'    AS usage_type, 12.0000 AS usd_per_chip_hour),
  STRUCT('tpu7x',                              'Preemptible',  4.3320),
  STRUCT('tpu-v6e-slice',                      'OnDemand',     2.7000),
  STRUCT('tpu-v5p-slice',                      'OnDemand',     4.2000),
  STRUCT('tpu-v5-lite-podslice',               'OnDemand',     1.2000),
  STRUCT('tpu-v4-podslice',                    'OnDemand',     3.2200)
]);
