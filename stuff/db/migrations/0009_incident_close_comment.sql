-- ---------------------------------------------------------------------------
-- 0009 — Optional closing comment on an incident
-- ---------------------------------------------------------------------------
-- When a user closes an incident they can leave an optional note (what they
-- did, context). Idempotent.
-- ---------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.incidents
  ADD COLUMN IF NOT EXISTS close_comment text;

COMMIT;
