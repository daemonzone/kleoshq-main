-- Split the processing/analysis record out of `ingestions` into `scan_reports`.
--
-- `ingestions` stays the raw intake row (payload, status, errors). The processor
-- writes one `scan_reports` row per processed (non-empty) report (`results` = the
-- wp.events diff) and the DB assigns its `id` (a uuidv7); the processor uses that
-- id both to name the changed-files archive in R2 (<id>.zip) and as the key the
-- analyzer later fills the analysis columns against.
--
-- `scan_reports.id` (a uuidv7, DB default) is the diff's canonical identifier;
-- the plugin sends no id of its own. Backfilled rows simply get a fresh id.
--
-- The row is SELF-CONTAINED (source_id, site_identifier, event_type denormalized)
-- and only loosely linked to its ingestion (ON DELETE SET NULL), so `ingestions`
-- can be purged later without losing the verdict history.
--
-- ADDITIVE and safe to run on a live database. Dropping the now-duplicated columns
-- from `ingestions` is a SEPARATE script (0003), to run only once the processor/
-- analyzer code uses `scan_reports`.
--
--   docker exec -i kleoshq-postgres psql -U kleos -d kleoshq_development \
--     -v ON_ERROR_STOP=1 < 0002_create_scan_reports_and_backfill.sql

BEGIN;

-- uuidv7 generator (Postgres < 18 has no native uuidv7()). Time-ordered so the
-- primary-key index stays locally sequential; 74 random bits keep it collision-safe.
-- gen_random_uuid() already sets the variant bits; we overlay the 48-bit timestamp
-- and force the version nibble to 7.
CREATE OR REPLACE FUNCTION public.uuidv7() RETURNS uuid
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v  bytea;
    ms bigint;
BEGIN
    ms := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
    v  := uuid_send(gen_random_uuid());
    v  := overlay(v placing substring(int8send(ms) FROM 3 FOR 6) FROM 1 FOR 6);  -- bytes 0..5 = ms
    v  := set_byte(v, 6, (get_byte(v, 6) & 15) | 112);                           -- version = 7
    RETURN encode(v, 'hex')::uuid;
END $$;

CREATE TABLE IF NOT EXISTS public.scan_reports (
    id                 uuid PRIMARY KEY DEFAULT public.uuidv7(),
    ingestion_id       bigint REFERENCES public.ingestions(id) ON DELETE SET NULL,
    source_id          uuid,
    site_identifier    character varying,
    event_type         character varying,
    results            jsonb NOT NULL DEFAULT '{}'::jsonb,   -- wp.events diff (processor)
    analyzed_at        timestamp with time zone,             -- NULL = not yet analyzed
    analysis_results   jsonb NOT NULL DEFAULT '{}'::jsonb,   -- AI verdict (analyzer)
    analysis_status    character varying,                    -- legit | malicious | suspicious (was "unknown" until migration 0011)
    analysis_certainty integer,
    created_at         timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT scan_reports_ingestion_id_key UNIQUE (ingestion_id),
    CONSTRAINT scan_reports_analysis_status_check
        CHECK (analysis_status IS NULL OR analysis_status IN ('legit','malicious','unknown')),
    CONSTRAINT scan_reports_analysis_certainty_check
        CHECK (analysis_certainty IS NULL OR (analysis_certainty >= 0 AND analysis_certainty <= 100))
);

CREATE INDEX IF NOT EXISTS scan_reports_source_id_idx ON public.scan_reports (source_id);
CREATE INDEX IF NOT EXISTS scan_reports_pending_analysis_idx
    ON public.scan_reports (source_id, created_at) WHERE analyzed_at IS NULL;

-- Backfill every processed report (non-empty diff) with its analysis, if any.
-- `id` is omitted so the uuidv7 default assigns it.
INSERT INTO public.scan_reports
    (ingestion_id, source_id, site_identifier, event_type, results,
     analyzed_at, analysis_results, analysis_status, analysis_certainty, created_at)
SELECT
    i.id, i.source_id, i.site_identifier, i.event_type, i.results,
    i.analyzed_at, i.analysis_results, i.analysis_status, i.analysis_certainty, i.ingested_at
FROM public.ingestions i
WHERE i.results IS NOT NULL AND i.results <> '{}'::jsonb
ON CONFLICT (ingestion_id) DO NOTHING;

COMMIT;
