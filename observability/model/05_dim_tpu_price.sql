-- dim_tpu_price: the TPU rate card, joined wherever chip-hours become money.
--
-- **The rates are not in this repository.** They are commercial terms, so the
-- table is created empty here and populated out of band -- see
-- collect/load_tpu_price.sh, which loads a CSV from a GCS path given at deploy
-- time. Nothing in git, in the mirror under primatrix/maxtext, or in a code
-- review carries a number.
--
-- CREATE TABLE IF NOT EXISTS, deliberately. Every model file is re-run on each
-- deploy and a CREATE OR REPLACE would silently empty the rate card on a
-- routine deploy, turning every cost column NULL with no error anywhere.
--
-- An empty table is the safe failure: costs come out NULL rather than wrong.
-- A fresh project therefore shows chip-hours and ratios -- which need no rate
-- card -- and no currency until someone loads one.
--
-- ---------------------------------------------------------------------------
-- What the columns mean, which is the part worth writing down:
--
--   tpu_model   must match the `model` metric label on
--               kubernetes.io/container/accelerator/* exactly. Those are GKE
--               accelerator names, not the marketing names on the price list:
--               observed values are tpu7x, tpu-v5-lite-podslice, tpu-v6e-slice,
--               tpu-v5p-slice. A first version keyed on 'v6e'/'v5p' and joined
--               to nothing, leaving every cost column NULL.
--
--   usage_type  OnDemand, Commit1Yr, Commit3Yr, CalendarReserved, Preemptible.
--               Which one applies is a property of how the capacity was bought,
--               not of the workload. Reserved capacity backed by a commitment
--               does not bill on demand, and pricing it that way overstates the
--               figure by the whole commitment discount -- fin_daily selects
--               Commit3Yr because this fleet's reservations are covered by
--               ACTIVE 36-month commitments, verified through the reservation's
--               linkedCommitments and the commitments' own accelerator counts.
--
--   usd_per_chip_hour
--               Per chip, not per host. The SKU description gives only
--               "usageUnit: h" and this was open for weeks. It is settled by
--               four independent checks: the region's on-demand TPU SKUs form a
--               single family whose three older generations each match their
--               published per-chip-hour list price, and this project's
--               commitments are denominated in ACCELERATOR with amounts equal
--               to the reservations' chip counts.
--
-- Not reconciled to an invoice. No Cloud Billing BigQuery export exists in
-- either project, so whatever is loaded here is a rate card and not a bill:
-- discounts, credits and mid-period commitment changes are not reflected.
-- Creating that export is the fix, and until it exists every currency column
-- is an estimate that happens to be precise.

CREATE TABLE IF NOT EXISTS mlobs_core.dim_tpu_price
(
  tpu_model         STRING,
  usage_type        STRING,
  usd_per_chip_hour FLOAT64
);
