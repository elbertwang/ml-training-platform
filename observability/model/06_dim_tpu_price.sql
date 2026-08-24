-- dim_tpu_price: TPU rate card, joined to fact_goodput to turn chip-hours into
-- money. Kept as a table (not hard-coded in the view) so it can be corrected
-- without a model change and so committed/spot rates can be added per job later.
--
-- Rates below are on-demand list prices pulled from the Cloud Billing Catalog
-- API for us-central1 on 2026-08-24.
--
-- !! VERIFY BEFORE TRUSTING THE COST COLUMNS !!
-- The catalog SKU reads "TPU7x running in Americas ... usageUnit: h" and does
-- not state whether the hour is per *chip* or per *host* (a tpu7x-standard-4t
-- host carries 4 chips). We assume per chip-hour, consistent with the published
-- TPU pricing pages and with the v6e SKU ($2.70/h) matching its per-chip list
-- price. If the real invoice says otherwise, every cost figure here is off by
-- 4x. Reconcile against a Cloud Billing BigQuery export once one exists --
-- there is no billing export in this project today.
--
-- This cluster is 37 x tpu7x-standard-4t and 2 x ct5p-hightpu-4t.

CREATE OR REPLACE TABLE `tpu-for-training.mlobs_core.dim_tpu_price` AS
SELECT * FROM UNNEST([
  STRUCT('tpu7x'  AS tpu_model, 'us-central1' AS region, 'OnDemand' AS usage_type,
         12.00    AS usd_per_chip_hour, DATE '2026-08-24' AS priced_on),
  STRUCT('tpu7x',  'us-central1', 'Preemptible',  4.3320, DATE '2026-08-24'),
  STRUCT('v5p',    'us-central1', 'OnDemand',     4.2000, DATE '2026-08-24'),
  STRUCT('v6e',    'us-central1', 'OnDemand',     2.7000, DATE '2026-08-24')
]);
