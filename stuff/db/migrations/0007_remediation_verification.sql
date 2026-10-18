-- ---------------------------------------------------------------------------
-- 0007 — Per-step verification command
-- ---------------------------------------------------------------------------
-- Each remediation step can carry an optional command / SQL / WP-CLI query the
-- owner runs to verify that step (e.g. confirm a file/plugin/user is gone, or
-- surface hidden ones). Idempotent.
-- ---------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.incident_remediation_steps
  ADD COLUMN IF NOT EXISTS verification text;

COMMIT;
