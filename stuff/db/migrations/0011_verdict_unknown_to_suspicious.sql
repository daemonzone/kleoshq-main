-- 0011 — rename the analyzer verdict "unknown" to "suspicious".
--
-- The verdict (scan_reports.analysis_status, and the same value inside
-- analysis_results->>'status') is now  legit | malicious | suspicious.
--
-- ORDER MATTERS on a shared database: run this and deploy the analyzer + public-www
-- that write/read "suspicious" together. Rows written as "unknown" after this
-- migration are rejected by the CHECK; old code reading "suspicious" would not
-- recognise it.  Idempotent: re-running changes nothing.

BEGIN;

ALTER TABLE scan_reports DROP CONSTRAINT IF EXISTS scan_reports_analysis_status_check;

UPDATE scan_reports
   SET analysis_status = 'suspicious'
 WHERE analysis_status = 'unknown';

UPDATE scan_reports
   SET analysis_results = jsonb_set(analysis_results, '{status}', '"suspicious"')
 WHERE analysis_results->>'status' = 'unknown';

ALTER TABLE scan_reports
  ADD CONSTRAINT scan_reports_analysis_status_check
  CHECK (analysis_status IS NULL OR analysis_status IN ('legit', 'malicious', 'suspicious'));

COMMIT;
