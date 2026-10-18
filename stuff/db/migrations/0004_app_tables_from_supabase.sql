-- Move the app tables (channels, websites, sources) from Supabase to the Neon
-- event store, so Neon is the single source of truth. Supabase keeps only Auth:
-- `user_id` is the Supabase Auth user id, stored as a plain uuid (no FK — auth
-- lives in another database).
--
-- Also:
--   - drops the legacy Rails `sources` table (bigint ids, unused, nothing
--     depends on it) — only when it is still the legacy shape, so a re-run never
--     drops the new table;
--   - adds `sources.status` (healthy | warning | compromised | not scanned yet);
--   - creates the NOLOGIN group role `app_web` for the web app, with
--     least-privilege grants and row-level security: the web app sets
--     `app.user_id` per transaction and only ever sees its own rows.
--
-- Services that connect as the table owner (agents, processor, analyzer) are not
-- subject to RLS (ENABLE, not FORCE). The web app must log in with a role that
-- is a member of `app_web` and is NOT the owner — see the role notes at the end.
--
-- Safe to re-run. After it, copy the data from Supabase (preserving the uuids:
-- ingestions/scan_reports.source_id already hold Supabase sources.id values).
--
--   docker exec -i kleoshq-postgres psql -U kleos -d kleoshq_development \
--     -v ON_ERROR_STOP=1 < 0004_app_tables_from_supabase.sql

BEGIN;

-- ---------------------------------------------------------------------------
-- Legacy Rails `sources` (bigint) — drop only if it still has the legacy shape
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'sources'
          AND column_name = 'id' AND data_type = 'bigint'
    ) THEN
        DROP TABLE public.sources;
        DROP SEQUENCE IF EXISTS public.sources_id_seq;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- channels (managed by us, read-only for users)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.channels (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    icon        text NOT NULL DEFAULT '',
    webhook_url text NOT NULL DEFAULT '',
    description text NOT NULL DEFAULT '',
    enabled     boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- websites (one per user for now)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.websites (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL,                 -- Supabase Auth user id
    name       text NOT NULL,
    url        text NOT NULL,
    slug       text NOT NULL,
    enabled    boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT websites_url_unique  UNIQUE (url),
    CONSTRAINT websites_slug_unique UNIQUE (slug)
);
CREATE INDEX IF NOT EXISTS websites_user_id_idx ON public.websites (user_id);

-- ---------------------------------------------------------------------------
-- sources (one per website and channel); `id` is the [slug] in the agent URLs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sources (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL,          -- Supabase Auth user id
    website_id        uuid REFERENCES public.websites(id) ON DELETE SET NULL,
    channel_code      text NOT NULL REFERENCES public.channels(code) ON DELETE RESTRICT,
    name              text NOT NULL,
    hmac              text NOT NULL,
    enabled           boolean NOT NULL DEFAULT true,
    status            text NOT NULL DEFAULT 'not scanned yet',
    status_changed_at timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sources_website_channel_unique UNIQUE (website_id, channel_code),
    CONSTRAINT sources_status_check
        CHECK (status IN ('healthy', 'warning', 'compromised', 'not scanned yet'))
);
CREATE INDEX IF NOT EXISTS sources_user_id_idx ON public.sources (user_id);

-- ---------------------------------------------------------------------------
-- Channel catalogue (same rows as kleoshq-public-www/supabase/seed_channels.sql)
-- ---------------------------------------------------------------------------
INSERT INTO public.channels (code, name, icon, webhook_url, description, enabled) VALUES
  ('woocommerce', 'WooCommerce', '🛒', 'https://hooks.kleoshq.com/woocommerce', 'Ricevi eventi da negozi WooCommerce: ordini, carrelli abbandonati, aggiornamenti prodotti.',          true),
  ('sitewitness', 'SiteWitness', '👁️', 'https://hooks.kleoshq.com/sitewitness', 'Monitora il comportamento degli utenti sul tuo sito: sessioni, click, scroll e conversioni.',       true),
  ('shopify',     'Shopify',     '🏪', 'https://hooks.kleoshq.com/shopify',     'Integra negozi Shopify per ricevere notifiche su ordini, clienti e aggiornamenti inventario.',       true),
  ('magento',     'Magento',     '🔶', 'https://hooks.kleoshq.com/magento',     'Connetti store Magento per sincronizzare ordini, catalogo prodotti e dati clienti.',                 false),
  ('prestashop',  'PrestaShop',  '🐾', 'https://hooks.kleoshq.com/prestashop',  'Ricevi dati da negozi PrestaShop: ordini, prodotti e aggiornamenti del catalogo in tempo reale.',   false),
  ('custom',      'Custom',      '⚙️', 'https://hooks.kleoshq.com/custom',      'Integrazione personalizzata via webhook generico — compatibile con qualsiasi piattaforma o CMS.',   false)
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Web app role: least privilege + row-level security
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_web') THEN
        CREATE ROLE app_web NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO app_web;
GRANT SELECT ON public.channels TO app_web;

-- Users manage their website and sources, but never `user_id` after creation
-- and never `status` (written by the analyzer only).
GRANT SELECT, DELETE ON public.websites, public.sources TO app_web;
GRANT INSERT (user_id, name, url, slug, enabled)                          ON public.websites TO app_web;
GRANT UPDATE (name, url, slug, enabled)                                   ON public.websites TO app_web;
GRANT INSERT (user_id, website_id, channel_code, name, hmac, enabled)     ON public.sources  TO app_web;
GRANT UPDATE (website_id, channel_code, name, hmac, enabled)              ON public.sources  TO app_web;

ALTER TABLE public.websites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sources  ENABLE ROW LEVEL SECURITY;

-- `current_setting('app.user_id', true)` is NULL when the app did not set it:
-- then no row matches, so a missing setting fails closed (sees nothing).
DROP POLICY IF EXISTS websites_own ON public.websites;
CREATE POLICY websites_own ON public.websites FOR ALL TO app_web
    USING      (user_id = nullif(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = nullif(current_setting('app.user_id', true), '')::uuid);

DROP POLICY IF EXISTS sources_own ON public.sources;
CREATE POLICY sources_own ON public.sources FOR ALL TO app_web
    USING      (user_id = nullif(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = nullif(current_setting('app.user_id', true), '')::uuid);

COMMIT;

-- ---------------------------------------------------------------------------
-- Login role for the web app (run once per environment, NOT part of this file
-- because it holds a password). Create it with SQL so it is a plain role, then
-- check it cannot bypass RLS:
--
--   CREATE ROLE kleoshq_web LOGIN PASSWORD '<strong password>' IN ROLE app_web;
--   SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'kleoshq_web';
--   -- expected: rolsuper = f, rolbypassrls = f
--
-- Locally this is done by stuff/db/local/create_web_role.sql.
-- ---------------------------------------------------------------------------
