// One-off: export channels / websites / sources from Supabase as SQL upserts for
// the Neon tables created by migrations/0004_app_tables_from_supabase.sql.
// Preserves every uuid (ingestions/scan_reports.source_id already hold them).
//
// The output CONTAINS SOURCE HMAC SECRETS: pipe it straight into psql, never
// save it to a file in the repository.
//
//   node --env-file=kleoshq-sitewitness-agent/.env stuff/db/scripts/export_supabase_app_tables.mjs \
//     | docker exec -i kleoshq-postgres psql -U kleos -d kleoshq_development -v ON_ERROR_STOP=1
//
// Production: same command, psql pointed at the Neon connection string (owner role):
//     | docker exec -i kleoshq-postgres psql "<neon owner connection string>" -v ON_ERROR_STOP=1
//
// Needs SUPABASE_URL and SUPABASE_SECRET_KEY (service key: reads past RLS).
// supabase-js is resolved from kleoshq-public-www, which keeps it for Auth.

import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const require = createRequire(path.resolve(here, '../../../kleoshq-public-www/package.json'))
const { createClient } = require('@supabase/supabase-js')

const { SUPABASE_URL, SUPABASE_SECRET_KEY } = process.env
if (!SUPABASE_URL || !SUPABASE_SECRET_KEY) {
  console.error('SUPABASE_URL and SUPABASE_SECRET_KEY are required')
  process.exit(2)
}
const supabase = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { persistSession: false } })

async function all(table, columns) {
  const { data, error } = await supabase.from(table).select(columns).order('created_at')
  if (error) throw new Error(`${table}: ${error.message}`)
  return data ?? []
}

const channels = await all('channels', 'id, code, name, icon, webhook_url, description, enabled, created_at')
const websites = await all('websites', 'id, user_id, name, url, slug, enabled, created_at')
const sources  = await all('sources',  'id, user_id, website_id, channel_code, name, hmac, enabled, created_at')

// JSON goes in a dollar-quoted literal; pick a tag that cannot occur inside it.
const json = rows => {
  const text = JSON.stringify(rows)
  let tag = 'kq'
  while (text.includes(`$${tag}$`)) tag += 'x'
  return `$${tag}$${text}$${tag}$`
}

console.log(`-- exported from Supabase: ${channels.length} channels, ${websites.length} websites, ${sources.length} sources
BEGIN;

INSERT INTO public.channels (id, code, name, icon, webhook_url, description, enabled, created_at)
SELECT x.* FROM json_to_recordset(${json(channels)}) AS x(
  id uuid, code text, name text, icon text, webhook_url text, description text, enabled boolean, created_at timestamptz)
ON CONFLICT (code) DO UPDATE SET
  id = EXCLUDED.id, name = EXCLUDED.name, icon = EXCLUDED.icon, webhook_url = EXCLUDED.webhook_url,
  description = EXCLUDED.description, enabled = EXCLUDED.enabled, created_at = EXCLUDED.created_at;

INSERT INTO public.websites (id, user_id, name, url, slug, enabled, created_at)
SELECT x.* FROM json_to_recordset(${json(websites)}) AS x(
  id uuid, user_id uuid, name text, url text, slug text, enabled boolean, created_at timestamptz)
ON CONFLICT (id) DO UPDATE SET
  user_id = EXCLUDED.user_id, name = EXCLUDED.name, url = EXCLUDED.url, slug = EXCLUDED.slug,
  enabled = EXCLUDED.enabled, created_at = EXCLUDED.created_at;

INSERT INTO public.sources (id, user_id, website_id, channel_code, name, hmac, enabled, created_at)
SELECT x.* FROM json_to_recordset(${json(sources)}) AS x(
  id uuid, user_id uuid, website_id uuid, channel_code text, name text, hmac text, enabled boolean, created_at timestamptz)
ON CONFLICT (id) DO UPDATE SET
  user_id = EXCLUDED.user_id, website_id = EXCLUDED.website_id, channel_code = EXCLUDED.channel_code,
  name = EXCLUDED.name, hmac = EXCLUDED.hmac, enabled = EXCLUDED.enabled, created_at = EXCLUDED.created_at;

COMMIT;`)
