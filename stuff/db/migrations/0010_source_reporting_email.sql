-- ---------------------------------------------------------------------------
-- 0010 — Reporting email per service (source)
-- ---------------------------------------------------------------------------
-- Where malicious-scan alerts for THIS service are sent. Set when the service
-- is created (defaults to the owner's email in the UI); the analyzer sends the
-- alert here. Idempotent.
-- ---------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.sources
  ADD COLUMN IF NOT EXISTS reporting_email text;

COMMIT;
