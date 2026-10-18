-- ---------------------------------------------------------------------------
-- 0008 — Per-step priority
-- ---------------------------------------------------------------------------
-- Each remediation step gets a priority so the owner sees what is mandatory
-- (remove the backdoor) vs secondary (final re-scan): critical > urgent >
-- medium > low. Idempotent.
-- ---------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.incident_remediation_steps
  ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'medium'
  CHECK (priority IN ('critical', 'urgent', 'medium', 'low'));

COMMIT;
