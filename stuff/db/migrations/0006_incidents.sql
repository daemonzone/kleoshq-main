-- ---------------------------------------------------------------------------
-- 0006 — Incidents + remediation steps
-- ---------------------------------------------------------------------------
-- A user opens an incident from a malicious scan_report. The analyzer produces
-- a short remediation summary and an ordered list of steps (stored here).
-- Closing the incident parks the source in 'awaiting_verification' until the
-- next scan judges the user's manual fixes.
-- Idempotent. Run as the database owner.
-- ---------------------------------------------------------------------------

BEGIN;

-- New source status used while a closed incident awaits the next scan's verdict.
-- 'awaiting_verification' is NOT sticky (unlike 'compromised'): a later 'legit'
-- delta promotes the source back to 'healthy' on its own.
ALTER TABLE public.sources DROP CONSTRAINT IF EXISTS sources_status_check;
ALTER TABLE public.sources ADD CONSTRAINT sources_status_check
  CHECK (status IN ('healthy', 'warning', 'compromised', 'not scanned yet', 'awaiting_verification'));

CREATE TABLE IF NOT EXISTS public.incidents (
  id             uuid PRIMARY KEY DEFAULT public.uuidv7(),
  user_id        uuid NOT NULL,                                  -- Supabase user id (tenant)
  source_id      uuid NOT NULL REFERENCES public.sources(id)      ON DELETE CASCADE,
  scan_report_id uuid          REFERENCES public.scan_reports(id) ON DELETE SET NULL,
  status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  summary        text,                                           -- analyzer-generated "what to do"
  created_at     timestamptz NOT NULL DEFAULT now(),
  closed_at      timestamptz,
  CONSTRAINT incidents_scan_report_unique UNIQUE (scan_report_id)  -- one incident per report
);
CREATE INDEX IF NOT EXISTS incidents_source_id_idx ON public.incidents (source_id);
CREATE INDEX IF NOT EXISTS incidents_user_id_idx   ON public.incidents (user_id);

CREATE TABLE IF NOT EXISTS public.incident_remediation_steps (
  id          uuid PRIMARY KEY DEFAULT public.uuidv7(),
  incident_id uuid NOT NULL REFERENCES public.incidents(id) ON DELETE CASCADE,
  position    integer NOT NULL DEFAULT 0,
  file_path   text,                 -- the file the step concerns, if any
  instruction text NOT NULL,        -- the action the user performs manually
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS incident_steps_incident_id_idx
  ON public.incident_remediation_steps (incident_id, position);

COMMIT;
