-- ---------------------------------------------------------------------------
-- 0010 — Notification email per website
-- ---------------------------------------------------------------------------
-- Where malicious-scan alert emails are sent for a site. The web app fills it
-- with the owner's email at creation; the analyzer reads it (falling back to an
-- operator ALERT_EMAIL_TO when null). Idempotent.
-- ---------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.websites
  ADD COLUMN IF NOT EXISTS notification_email text;

COMMIT;
