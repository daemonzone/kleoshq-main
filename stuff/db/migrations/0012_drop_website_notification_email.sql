-- ---------------------------------------------------------------------------
-- 0012 — Drop the redundant websites.notification_email
-- ---------------------------------------------------------------------------
-- The reporting email is now per-service (sources.reporting_email, 0011).
-- websites.notification_email (0010) is no longer used. Idempotent.
-- ---------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.websites DROP COLUMN IF EXISTS notification_email;

COMMIT;
