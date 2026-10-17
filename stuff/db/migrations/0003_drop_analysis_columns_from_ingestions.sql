-- Drop the columns now owned by `scan_reports` from `ingestions`.
--
-- DESTRUCTIVE. Run only AFTER 0002 has backfilled `scan_reports` AND the
-- processor / analyzer code no longer writes these columns — otherwise the
-- running services break (the processor writes `ingestions.results`).
--
-- `report_id` is intentionally not handled here: it was never deployed to
-- production. An environment that applied the interim 0001 can drop its leftover
-- column separately (ALTER TABLE ingestions DROP COLUMN IF EXISTS report_id).
--
-- `v_ingestions` lists these columns, so it is dropped and recreated without them.
-- Inline CHECK constraints and the partial `index_ingestions_pending_analysis`
-- (WHERE analyzed_at IS NULL) are removed automatically with their columns.
--
--   docker exec -i kleoshq-postgres psql -U kleos -d kleoshq_development \
--     -v ON_ERROR_STOP=1 < 0003_drop_analysis_columns_from_ingestions.sql

BEGIN;

-- Guard: refuse to drop until every processed ingestion has a scan_reports row.
DO $$
DECLARE
    missing bigint;
BEGIN
    SELECT count(*) INTO missing
    FROM public.ingestions i
    WHERE i.results IS NOT NULL AND i.results <> '{}'::jsonb
      AND NOT EXISTS (SELECT 1 FROM public.scan_reports s WHERE s.ingestion_id = i.id);
    IF missing > 0 THEN
        RAISE EXCEPTION 'Aborting: % processed ingestion(s) not yet in scan_reports — run 0002 first', missing;
    END IF;
END $$;

DROP VIEW IF EXISTS public.v_ingestions;

ALTER TABLE public.ingestions
    DROP COLUMN IF EXISTS results,
    DROP COLUMN IF EXISTS analyzed_at,
    DROP COLUMN IF EXISTS analysis_results,
    DROP COLUMN IF EXISTS analysis_status,
    DROP COLUMN IF EXISTS analysis_certainty;

CREATE VIEW public.v_ingestions AS
 SELECT id,
    site_identifier,
    source_id,
    event_type,
    ingested_at,
    status,
    errors
   FROM public.ingestions
  ORDER BY id;

COMMIT;
