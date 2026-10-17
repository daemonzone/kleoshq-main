-- Adds the report_id column the SiteWitness plugin now stamps on every report.
-- Safe to run on an existing database (the schema reference already carries the
-- column, so fresh local volumes don't need this).
--
--   psql "$NEON_DATABASE_URL" -f 0001_ingestions_report_id.sql

ALTER TABLE public.ingestions
    ADD COLUMN IF NOT EXISTS report_id uuid;

-- Lets the analyzer find an ingestion (and its <report_id>.zip in R2) by id.
CREATE INDEX IF NOT EXISTS ingestions_report_id_idx
    ON public.ingestions (report_id);
