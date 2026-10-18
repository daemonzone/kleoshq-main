-- ---------------------------------------------------------------------------
-- 0005 — Drop the dedicated web role and row-level security
-- ---------------------------------------------------------------------------
-- 0004 set up a least-privilege `app_web` group role, a `kleoshq_web` login
-- role and row-level security on `websites`/`sources`. We dropped that model:
-- the web app now connects with the owner connection string like every other
-- service, and tenant isolation is enforced in application queries
-- (`WHERE user_id = …`), not by RLS.
--
-- This migration tears all of that down. It is idempotent — safe to run on an
-- environment that never had the role/RLS, and safe to run twice.
-- Run it as the database owner.
-- ---------------------------------------------------------------------------

BEGIN;

-- Drop the policies and disable RLS on the app tables.
DROP POLICY IF EXISTS websites_own ON public.websites;
DROP POLICY IF EXISTS sources_own  ON public.sources;

ALTER TABLE IF EXISTS public.websites DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.sources  DISABLE ROW LEVEL SECURITY;

-- Drop the login role first (it is a member of app_web), then the group role.
-- DROP OWNED BY clears any remaining grants so DROP ROLE cannot fail on deps.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kleoshq_web') THEN
        EXECUTE 'DROP OWNED BY kleoshq_web';
        EXECUTE 'DROP ROLE kleoshq_web';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_web') THEN
        EXECUTE 'DROP OWNED BY app_web';
        EXECUTE 'DROP ROLE app_web';
    END IF;
END $$;

COMMIT;
