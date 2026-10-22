# KleosHQ

KleosHQ collects events from WordPress and WooCommerce sites into an external event store, monitors site integrity, and uses AI to judge whether detected changes are legitimate maintenance or a compromise.

Sites run two small WordPress plugins that push data out over signed webhooks. Serverless receivers on Vercel validate and store that data in PostgreSQL (Neon). Processors then turn raw integrity reports into change events and analyze them. A Next.js web app lets users register their websites and sources.

This root folder is a workspace: each subproject is its own git repository. The root repository only versions shared material (this README, `stuff/`, build artifacts); see [Workspace repository](#workspace-repository).

---

## Contents

- [Architecture](#architecture)
- [Subprojects](#subprojects)
- [Data stores](#data-stores)
- [Ingestion lifecycle](#ingestion-lifecycle)
- [Local development](#local-development)
- [Database setup on a new environment](#database-setup-on-a-new-environment)
- [Workspace repository](#workspace-repository)
- [Security notes](#security-notes)
- [Known gaps and next steps](#known-gaps-and-next-steps)

---

## Architecture

Two pipelines share one Neon database, which also holds the source registry (`channels`, `websites`, `sources`). Supabase is used for user authentication only.

### Site integrity (SiteWitness)

```
WordPress site
 └─ wp-sitewitness (plugin)            hashes files, checks DB risk patterns, daily snapshot
        │  POST, X-SiteWitness-Signature: sha256=HMAC(body)
        ▼
kleoshq-sitewitness-agent              POST /api/ingest/[slug]
  - looks up the source in Neon (sources.id = slug, enabled), verifies the HMAC
  - dedupes on slug + payload hash
  - INSERT ingestions (status 'pending') + ingestions_log
        │  POST { source_id }
        ▼
kleoshq-ingestion-processor            POST /api/process
  - diffs each pending report against the previous processed one
  - inserts a scan_reports row (wp.events patch in results, DB-assigned uuidv7 id),
    marks the ingestion 'processed' (or deletes it when nothing changed)
  - on changed files: calls the plugin's /collect with a presigned R2 PUT URL
    ──▶ the plugin archives the changed files to R2 as <scan_report id>.zip
        │  POST { source_id }    in the background, when ANALYZER_URL is set
        ▼
kleoshq-ingestion-analyzer             POST /api/analyze
  - pre-analyzes every not-yet-analyzed scan_report in code
  - downloads <scan_report id>.zip from R2 and inspects the unverified files' code
  - asks an AI for a verdict: legit | malicious | suspicious + certainty + description
    + code_inspection (per-file + cross-file)
  - writes analyzed_at, analysis_results, analysis_status, analysis_certainty on the scan_report
```

Changed files are captured directly from the live site into object storage (Cloudflare R2) so the analyzer can read their actual code, not just hashes. See each subproject's README for the collect/inspect details.

### Store events (StoreRelay)

```
WooCommerce store
 └─ wp-storerelay (plugin)             queues order / customer / product events, retries
        │  POST, x-wc-webhook-signature: sha256=HMAC(body)
        │       x-wc-webhook-event-type, x-wc-webhook-delivery-id, x-wc-aggregate-type/-id
        ▼
kleoshq-woocommerce-agent              POST /api/webhooks/woocommerce/[slug]
  - looks up the source in Neon, verifies the HMAC
  - INSERT events + events_processed_keys (idempotency)
```

### Management

```
kleoshq-public-www (Next.js; Supabase Auth for sign-in, Neon for data)
  - users sign in, register websites, create one source per website and channel
  - each source gets the HMAC secret the plugins and agents use
  - reads/writes Neon with the owner connection (tenant isolation enforced in the queries)
```

---

## Subprojects

| Folder | Stack | Role | Runs on |
|---|---|---|---|
| [`wp-sitewitness`](#wp-sitewitness) | WordPress plugin (PHP) | Integrity snapshots of a site | the customer's WordPress |
| [`wp-storerelay`](#wp-storerelay) | WordPress plugin (PHP) | Streams WooCommerce events | the customer's WordPress |
| [`kleoshq-sitewitness-agent`](#kleoshq-sitewitness-agent) | Node.js, Vercel Function | Receives SiteWitness reports | Vercel `kleoshq-sitewitness-ingester` |
| [`kleoshq-woocommerce-agent`](#kleoshq-woocommerce-agent) | Node.js, Vercel Function | Receives StoreRelay events | Vercel `kleoshq-receiver-nodejs` |
| [`kleoshq-ingestion-processor`](#kleoshq-ingestion-processor) | TypeScript, Vercel Function | Turns reports into change events | Vercel `kleoshq-ingestion-processor` |
| [`kleoshq-ingestion-analyzer`](#kleoshq-ingestion-analyzer) | TypeScript, Vercel Function | AI verdict on changes | Vercel `kleoshq-ingestion-analyzer` |
| [`kleoshq-public-www`](#kleoshq-public-www) | Next.js 16, React 19, Supabase Auth, Neon | Web app: websites and sources | Vercel / local |
| [`kleoshq_eventstore_api`](#kleoshq_eventstore_api-legacy) | Ruby on Rails 8.1 | **Legacy**: only used to define DB migrations | not used |

Each subproject has its own README with full details; the sections below summarize them.

### wp-sitewitness

WordPress plugin, *"silent integrity monitoring for WordPress"* (v0.3.2).

- MD5-hashes PHP, JS and HTML files across `wp-admin`, `wp-includes`, plugins, themes and mu-plugins, incrementally (mtime-based).
- DB checks: admin users, active plugins, mu-plugins, critical options, Elementor snippets, suspicious and recently created users.
- Keeps 7 days of JSON snapshots in `wp-content/sitewitness-data/` (protected by `.htaccess`).
- POSTs the report to the configured webhook with `X-SiteWitness-Signature: sha256=<HMAC>` and `X-SiteWitness-Host`. Each report carries a single-use `pull_nonce`.
- Exposes `POST /wp-json/sitewitness/v1/collect` (nonce-authenticated): on request it archives a given list of changed files to a presigned R2/S3 URL under a caller-supplied key (`<scan_report id>.zip`) — the plugin holds no cloud credentials.
- Configured in *Settings → SiteWitness*: webhook URL, secret, frequency (default daily), "Run snapshot now".

### wp-storerelay

WordPress plugin for WooCommerce (v1.0.2). Streams events to an external event store so store data survives the site and builds an immutable audit trail.

- Events: `order.created`, `order.payment_received`, `order.payment_failed`, `order.cancelled`, `order.refunded`, `order.completed`, `customer.created/updated/deleted`, `product.created/updated/deleted`.
- Queue with retry logic and idempotency keys; signs each body with HMAC-SHA256.
- Sends WooCommerce-style headers (`x-wc-webhook-*`, `x-wc-aggregate-type/-id`) so the receiver can treat it like a native WooCommerce webhook.
- Configured in *Settings → StoreRelay*: webhook URL, HMAC secret, enabled events.

### kleoshq-sitewitness-agent

Vercel Function receiving SiteWitness reports: `POST /api/ingest/[slug]`.

1. Validates the slug is a uuid, looks up the source in Neon (`sources.id = slug`, `enabled = true`) and verifies the HMAC with its `hmac` secret.
2. Builds the idempotency key `slug-<payload hash>` and inserts into `ingestions` (`ON CONFLICT DO NOTHING`, duplicates answer `{ ok: true, duplicate: true }`), plus a row in `ingestions_log` with the same id.
3. Fires `POST PROCESSOR_URL { source_id }` to start the processor.

Env: `DATABASE_URL` (Neon — ingestions and the source registry), `PROCESSOR_URL`. No Supabase credentials.

### kleoshq-woocommerce-agent

Vercel Function receiving StoreRelay (and native WooCommerce) webhooks: `POST /api/webhooks/woocommerce/[slug]`.

- Looks up the source in Neon, verifies `x-wc-webhook-signature`.
- Inserts into `events` (with `aggregate_type` / `aggregate_id` from the headers) and `events_processed_keys` for idempotency.
- `test-webhook.js` and `test-customer-webhook.js` send sample signed requests.

Env: `DATABASE_URL` (Neon). No Supabase credentials.

### kleoshq-ingestion-processor

Vercel Function: `POST /api/process { source_id }`.

- Takes every `pending` `sitewitness_report` of the source, oldest first; marks it `processing`.
- First report of a source: a single `snapshot.initial` event with the full site state. Later reports: a diff against the last `processed` one, as `wp.events` (`plugin.added/removed`, `mu_plugin.*`, `wp_version.changed`, `admin_user.*`, `suspicious_user.detected`, `critical_option.changed`, `elementor_snippet.*`, `file.added/removed/modified`).
- On a non-empty diff: inserts a `scan_reports` row (the patch in `results`, DB-assigned uuidv7 `id`) and marks the ingestion `processed`. Deletes ingestions whose diff is empty; marks `failed` with details in `errors` on error.
- On a non-empty diff with `file.added`/`file.modified` events and R2 configured: mints a presigned PUT URL (`lib/r2.ts`, dependency-free SigV4) and calls the plugin's `/collect` so the changed files are archived to R2 as `<scan_report id>.zip` while the report is fresh. Collection never fails processing — errors are only logged.
- When a run leaves at least one row `processed` and `ANALYZER_URL` is set, calls the analyzer for the source in the background (`waitUntil`), so the agent never waits for the AI.
- Uses `pg` for a localhost DB, the Neon serverless driver otherwise. `node simulate.mjs <source_id>` triggers it locally.

Env: `NEON_DATABASE_URL`, optional `ANALYZER_URL`, `ANALYZER_TRIGGER_TIMEOUT_MS`, the `R2_*` set + `SITEWITNESS_COLLECT_BASE_URL` / `COLLECT_TIMEOUT_MS` (changed-file collection), `LOG_LEVEL=debug`.

### kleoshq-ingestion-analyzer

Vercel Function: `POST /api/analyze { source_id }` (optional `Authorization: Bearer WEBHOOK_SECRET`).

- Analyzes every `processed` `sitewitness_report` of the source with `analyzed_at IS NULL`, oldest first, within a time budget (`ANALYZE_TIME_BUDGET_MS`, 240s; `maxDuration` 300s). Failed rows stay unanalyzed and are retried on the next call.
- **Pre-analysis in code** before the AI sees anything: groups events, classifies file changes (`wp_version_upgrade`, `extensions_update`, `few_changes`, `unexplained_mass_change`, `initial_snapshot`), summarizes mass changes per folder, verifies mu-plugins by MD5 against copies shipped inside installed plugins, verifies core files against the **official WordPress checksums** for the site's version (so a core file restored after a compromise reads as a clean-up, and one altered even during an upgrade is caught), and raises red flags (PHP in `uploads`, unverified mu-plugins, altered or foreign core files). Payloads of MBs become a few KB.
- **File-content inspection:** when files changed and R2 is set, downloads `<scan_report id>.zip`, selects the files not already proven genuine (plugin/theme code, uploads, altered/foreign core, unverified mu-plugins), and folds their actual contents into the **same** AI call (untrusted-data guarded). This closes the name-only plugin-directory gap.
- Calls any OpenAI-compatible Chat Completions endpoint: local Ollama, a local Claude Code bridge for testing (`npm run bridge`), or a hosted provider.
- **First scan = baseline:** a site's initial snapshot is recorded as a baseline **without an AI call** and promotes the source to `healthy`; judging a brand-new install would be noisy and flag whatever is already installed (SiteWitness included), so scoring starts from the first real delta.
- Stores the verdict on the `scan_reports` row: `analysis_status` (`legit` / `malicious` / `suspicious`, NULL for a baseline), `analysis_certainty` (0–100), `analysis_results` (JSON with description, `code_inspection` and model; the model bolds the threat/impact and remediation with `**…**`, never raw code tokens), `analyzed_at`. Then it drives the source's `status` from the verdict: `malicious` → `compromised` (**sticky**, cleared only by manual remediation), `unknown` → `warning`, `legit` → `healthy`.
- `samples/` holds labelled payloads; `npm run test:samples` checks them end-to-end.

Env: `NEON_DATABASE_URL`, `AI_API_URL`, `AI_API_KEY`, `AI_MODEL`, plus optional `WEBHOOK_SECRET`, `AI_TIMEOUT_MS`, `AI_MAX_PAYLOAD_CHARS`, `AI_JSON_MODE`, `MASS_FILE_CHANGE_THRESHOLD`, `ANALYZE_TIME_BUDGET_MS`, the `R2_*` set + `AI_MAX_FILE_BYTES` / `AI_MAX_FILE_CONTENT_CHARS` (file-content inspection), `LOG_LEVEL`.

### kleoshq-public-www

Next.js 16 (App Router) web app with React 19, Tailwind 4 and Supabase Auth. Note: Next.js 16 has breaking changes; see the project's `AGENTS.md`.

- Pages: home, login (+ auth callback), dashboard (multiple websites, each with aggregate status), per-website services (`/sources?website=<id>`) and service detail, incident detail (`/incidents/<id>`), profile. `proxy.ts` protects `/dashboard`, `/sources`, `/incidents`, `/profile`.
- **Languages (it/en):** `next-intl` without URL prefixes — the language lives in the `locale` cookie (default `it`), set by the EN | IT toggle in the navbar, so routes (and the intercepted service modal) keep the same address. Strings are in `messages/{it,en}.json`; server actions return localised errors via `lib/errors.ts`; dates go through `lib/format.ts`. Content generated by the analyzer (verdict descriptions, remediation steps) stays in Italian. Later the signed-in user's saved preference can be read in `i18n/request.ts`.
- Server actions for auth, websites, channels, sources and incidents. Auth goes through Supabase; all app data goes through `lib/db.ts` to Neon.
- **Incidents:** from a malicious/sospetto scan a user opens an incident; the analyzer (`POST /api/remediation`, via `ANALYZER_URL`) generates a summary + remediation steps; closing it parks the service in `awaiting_verification` (unless already healthy) until the next scan. An incident from a sospetto report is deletable, a malicious one is not.
- `lib/db.ts` (server-only) is the only module that touches the database; it connects with the owner connection string (like the other services). Tenant isolation is enforced in the queries: `withUser(userId, fn)` runs each action in a transaction, every statement filters on `user_id`, and a source can only point at one of the user's own websites.
- The channel catalogue is seeded by `stuff/db/migrations/0004_app_tables_from_supabase.sql` (WooCommerce, SiteWitness, Shopify enabled; Magento, PrestaShop, Custom planned). `supabase/schema.sql` / `seed_channels.sql` are kept for reference only — those Supabase tables are being retired.

Env (`.env.local`): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (auth), `DATABASE_URL` (Neon, owner connection — same as the agents). Optional `R2_*` (same variables as the processor) enable the incident page's evidence-archive download (presigned, read-only).

### kleoshq_eventstore_api (legacy)

Rails 8.1 / Ruby 3.4.9 API, the original design of an event-driven notification platform (sources, events, subscriptions, notification delivery, Devise JWT auth, Solid Queue, Kamal).

**It is no longer used at runtime.** It was only used to define the Neon schema through its migrations (`db/migrate`). Its `db/schema.rb` is out of date: the live schema has since gained `ingestions.status`/`errors`, the `scan_reports` table (the wp.events diff + the AI verdict), `ingestions_log` and `v_ingestions`, and `ingestions.source_id` is now a `uuid`. The current reference schema is the dump in `stuff/db/`.

---

## Data stores

### Supabase (authentication only)

User accounts (`auth.users`), sign-in, password reset. `websites.user_id` / `sources.user_id` in Neon hold the Supabase user id (plain uuid, no cross-database foreign key).

### Neon PostgreSQL (event store)

| Object | Written by | Content |
|---|---|---|
| `channels` | migration 0004 (seed) | integration types (`woocommerce`, `sitewitness`, `shopify`, …) with their public webhook URL; read-only for the web app |
| `websites` | web app | websites registered by a user (scoped to `user_id` by the app) |
| `sources` | web app, analyzer (`status`) | one per website and channel: `id` (uuid, the `[slug]` in the agent URLs), `hmac` secret, `enabled`, `status` (`healthy`/`warning`/`compromised`/`not scanned yet`/`awaiting_verification`); scoped to `user_id` by the app; read by the agents |
| `incidents`, `incident_remediation_steps` | web app | an incident opened from a malicious/sospetto scan, with the analyzer-generated remediation steps (migration `0006`) |
| `ingestions` | sitewitness-agent, processor | raw intake: `payload`, processing `status`, `errors` |
| `scan_reports` | processor, analyzer | one per processed report: `id` (uuidv7, names the R2 archive), `results` (wp.events diff), and the AI verdict (`analysis_status`/`_certainty`/`_results`, `analyzed_at`) |
| `ingestions_log` | sitewitness-agent | ingestion runs log, same ids as `ingestions` |
| `v_ingestions` | view | `ingestions` without the heavy `payload` |
| `events` | woocommerce-agent | store events with aggregate type/id and JSONB payload |
| `events_processed_keys` | woocommerce-agent | idempotency keys of processed store events |
| `events_projection_checkpoints` | (unused so far) | projection positions |
| `schema_migrations`, `ar_internal_metadata` | legacy Rails | not used by the current services |

> **Roles.** Every service — agents, processor, analyzer and the web app — connects with the owner connection string. The web app keeps users to their own rows in code: every query filters on the signed-in user's id (`lib/db.ts`), rather than relying on database row-level security.

The local database runs the `timescale/timescaledb:latest-pg17` image and has the TimescaleDB extension installed, but no table is a hypertable.

### Cloudflare R2 (changed-files archive)

| Object | Written by | Read by | Content |
|---|---|---|---|
| `<scan_report id>.zip` | wp-sitewitness (via a presigned PUT the processor mints) | ingestion-analyzer (presigned GET) | the files that changed in that report, directory structure preserved (`.tar.gz` when the plugin lacks `ZipArchive`) |

S3-compatible; the processor and analyzer share the `R2_*` env (`R2_ENDPOINT`, `R2_REGION=auto`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`). Leave them unset to run the pipeline without file collection/inspection (hash diffing still works). The WordPress plugin itself never holds R2 credentials — it only receives short-lived presigned URLs.

---

## Ingestion lifecycle

A SiteWitness report across `ingestions` and `scan_reports`:

| Step | Service | State |
|---|---|---|
| received | sitewitness-agent | `ingestions`: `status = 'pending'`, `payload` = full report |
| processing | processor | `ingestions`: `status = 'processing'` |
| changes found | processor | new `scan_reports` row (`results` = wp.events patch); `ingestions.status = 'processed'` |
| files archived | processor → plugin | changed files uploaded to R2 as `<scan_report id>.zip` (when files changed + R2 set) |
| nothing changed | processor | ingestion deleted, no `scan_reports` row |
| error | processor | `ingestions`: `status = 'failed'`, `errors` = message and stack |
| analyzed | analyzer | `scan_reports`: `analyzed_at` set; `analysis_status`, `analysis_certainty`, `analysis_results` (incl. `code_inspection`) filled (status/certainty stay NULL for empty results) |

---

## Local development

### Ports

| Service | Command (in its folder) | URL |
|---|---|---|
| ingestion-processor | `vercel dev` | http://localhost:3000 |
| public-www | `npm run dev` | http://localhost:3001 (when 3000 is taken) |
| ingestion-analyzer | `npx vercel dev --listen 3002` | http://localhost:3002 |
| Claude Code bridge (analyzer testing) | `npm run bridge` | http://localhost:11435 |
| Ollama (analyzer, local models) | `ollama serve` | http://localhost:11434 |
| PostgreSQL | Docker container `kleos_postgres` | localhost:5432, database `kleoshq_development` |

### Docker stack

`docker-compose.yml` at the root runs the whole pipeline under the `kleoshq` project, next to (not instead of) the host setup above: different ports, its own databases.

```bash
docker compose up -d --build     # start
docker compose logs -f <service> # follow one service
docker compose down              # stop; add -v to drop the data too
```

| Service | Container | URL |
|---|---|---|
| WordPress 7.1.1 with `wp-sitewitness` active | `kleoshq-wordpress` | http://localhost:8088 (`admin` / `admin_dev_password`) |
| Second WordPress (fresh, for testing site registration) | `kleoshq-wordpress2` | http://localhost:8089 (`admin` / `admin_dev_password`) — opt-in: `docker compose up -d wordpress2 wp-setup2` (db `wordpress2` on the shared `kleoshq-mysql`) |
| Third WordPress (fresh, same as wordpress2) | `kleoshq-wordpress3` | http://localhost:8090 (`admin` / `admin_dev_password`) — opt-in: `docker compose up -d wordpress3 wp-setup3` (db `wordpress3` on the shared `kleoshq-mysql`) |
| Fourth WordPress (pattyboop restored from `stuff/dumps/20260405`: files + DB dump, WP 6.8.1, prefix `WWr6Ek_`, URLs rewritten to localhost:8091, `WP_CACHE` off; `wp-sitewitness` active, unconfigured; may contain malicious files — it is the scanner's test subject) | `kleoshq-wordpress4` | http://localhost:8091 (db `wordpress4` on the shared `kleoshq-mysql`; login = a user from the restored DB, not `admin`) — opt-in: `docker compose up -d wordpress4` |
| public-www (`next dev`) | `kleoshq-public-www` | http://localhost:4000 |
| sitewitness-agent | `kleoshq-sitewitness-agent` | http://localhost:4001/api/ingest/[slug] |
| woocommerce-agent | `kleoshq-woocommerce-agent` | http://localhost:4002/api/webhooks/woocommerce/[slug] |
| ingestion-processor | `kleoshq-ingestion-processor` | http://localhost:4003/api/process |
| ingestion-analyzer | `kleoshq-ingestion-analyzer` | http://localhost:4004/api/analyze |
| MySQL 8.4 (all WordPress sites, one database each: `wordpress`, `wordpress2`, `wordpress3`, `wordpress4`) | `kleoshq-mysql` | localhost:3307 |
| PostgreSQL / TimescaleDB (event store) | `kleoshq-postgres` | localhost:5433, database `kleoshq_development` |

- **Vercel functions** are served by `docker/node/vercel-fn-server.mjs`, a small stand-in for the Vercel runtime (file routing under `api/`, `req.query` / `req.body`, `res.status().json()`), run with `tsx watch`: the subproject folders are bind-mounted, edits reload. No Vercel login needed. **Caveat:** `tsx watch` does not reliably reload handlers/libs imported dynamically, so after editing a function service (processor/analyzer/agents) restart it: `docker compose restart <service>` (or `up -d <service>` if you changed its env). Code lives in the bind mount, so a rebuild is not needed for app changes.
- **Configuration:** each service still reads its own `.env` / `.env.local` (Supabase auth keys for the web app, `AI_MODEL`, …). Compose overrides only the wiring: database URLs point to `kleoshq-postgres`, `PROCESSOR_URL` and `ANALYZER_URL` to the containers, `AI_API_URL` to the host (`host.docker.internal`, Claude Code bridge by default).
- **Object storage (R2):** the `R2_*` vars from the root `.env` are passed to the processor and analyzer (real Cloudflare R2, over the internet — there is no local S3 container). The processor derives the collect target from each report's own `site_url`, and in Docker gets `SITEWITNESS_COLLECT_LOCALHOST_AS=host.docker.internal` so a `localhost:<port>` host (unreachable from inside the container) is reached via the host gateway, keeping the report's port — so it works for every local site (8088, 8089, …), not a fixed one. Leave `R2_*` blank to run without changed-file collection/inspection.
- **Supabase is not part of the stack:** only the web app talks to it, for sign-in, using the project in its `.env.local`. The agents no longer use Supabase.
- **Event store:** created from `stuff/db/kleoshq_schema_and_reference_20261022.sql` the first time the volume is empty. Fill `websites`/`sources` with the export script below, or create them in the app.
- **Host-run services:** Postgres is published on `localhost:5433`, so a service run outside Docker needs `…@localhost:5433/kleoshq_development` (port 5432 has nothing listening).
- **WordPress:** `wp-setup` (wp-cli) installs the site and activates SiteWitness on every `up`. Set `SITEWITNESS_SOURCE_ID` and `SITEWITNESS_HMAC_SECRET` in the root `.env` (see `.env.example`) to have it configure the webhook too, then `docker compose up wp-setup`. `wp-storerelay` is mounted but inactive.
- Send a snapshot without the admin page: `docker compose run --rm --entrypoint wp wp-setup eval 'SW_Sender::run();'`

### Typical SiteWitness flow

```bash
# 1. the agent (or the plugin) inserts a pending ingestion, then:
cd kleoshq-ingestion-processor && node simulate.mjs <source_id> http://localhost:3000
# 2. analyze what was processed (automatic when the processor's ANALYZER_URL is set)
cd kleoshq-ingestion-analyzer  && node simulate.mjs <source_id> http://localhost:3002
```

Each Node service reads its own `.env` (copy it from the project's `env.sample`). A `NEON_DATABASE_URL` / `DATABASE_URL` containing `localhost` targets the local container.

`psql` is not installed on the host; run it through the container: `docker exec -i kleos_postgres psql …`.

---

## Database setup on a new environment

`stuff/db/kleoshq_schema_and_reference_20261022.sql` recreates the Neon database: the full `public` schema (tables incl. the app tables `channels`/`websites`/`sources`, `scan_reports`, `incidents` + `incident_remediation_steps`, the `uuidv7()` function, sequences, indexes, constraints, `v_ingestions`), plus reference rows (`channels`, `schema_migrations`, `ar_internal_metadata`, `events_projection_checkpoints`). It contains no ingestion or event data and does not require TimescaleDB.

The snapshot is generated from a database with migrations `stuff/db/migrations/0002`–`0011` applied (verdict `legit | malicious | suspicious`), so a database restored from it must **not** run those migrations — only the ones numbered above 0011. An already-existing database (e.g. the current Neon one) keeps being upgraded with the individual migrations.

```bash
# restore into an EMPTY database
docker exec -i kleos_postgres psql "<target connection string>" -v ON_ERROR_STOP=1 \
  < stuff/db/kleoshq_schema_and_reference_20261022.sql
```

To bring websites and sources over from Supabase (uuids preserved; the output contains HMAC secrets, so pipe it, never save it):

```bash
node --env-file=kleoshq-sitewitness-agent/.env stuff/db/scripts/export_supabase_app_tables.mjs \
  | docker exec -i kleoshq-postgres psql "<target owner connection string>" -v ON_ERROR_STOP=1
```

The dump reflects the current `scan_reports` model. A database created from an **older** dump is upgraded with the migrations in [`stuff/db/migrations/`](stuff/db/migrations/): run `0002_create_scan_reports_and_backfill.sql` (additive — creates `scan_reports`, backfills from the old `ingestions` columns) then `0003_drop_analysis_columns_from_ingestions.sql` (drops `results`/analysis columns from `ingestions`; run only once the services are on the new code). Then `0004_app_tables_from_supabase.sql` moves the app tables from Supabase: it drops the legacy Rails `sources` (bigint) table, creates `channels`/`websites`/`sources` and seeds the channels (`0005` removed the short-lived `app_web`/row-level-security setup — the web app uses the owner connection). All services use the owner connection string. Fresh databases from the dump need none of these migrations.

---

## Workspace repository

The root git repository versions only what belongs to no subproject:

| Path | Content |
|---|---|
| `README.md` | this file |
| `stuff/db/` | database dump for new environments |
| `stuff/procs/` | operational notes (start commands) |
| `stuff/*.png`, `*.png` | screenshots |

The packaged plugin builds at the root (`wp-storerelay_*.zip`) are not committed.

`.gitignore` excludes every subproject folder (each is versioned in its own repository), secrets, full data dumps, `.env` files and macOS clutter.

**Adding a subproject:** create its folder with its own `git init`, then add `/<folder>/` to the root `.gitignore`, otherwise the root repository will start tracking it.

---

## Security notes

- Every webhook is signed with HMAC-SHA256 over the raw body; secrets live in Neon `sources.hmac` and in each plugin's settings.
- The web app and the agents reach Neon with the owner connection string; the web app keeps each user to their own rows in code (every query filters on the signed-in user's id). The agents hold no Supabase credentials.
- Changed-file collection never ships credential files: the plugin's `/collect` and the analyzer's file selection both deny `wp-config.php` (and variants/backups) and `.env` files, so their contents are never archived to R2 or sent to the AI (they are still md5-hashed for integrity). R2 credentials never reach the WordPress plugin — it only receives short-lived presigned PUT URLs.
- `.env` files are never committed (root and subproject `.gitignore`s).
- `stuff/procs/db_restore.txt` contains live database credentials and is git-ignored; keep it that way, and rotate the password if the file was ever shared.
- `stuff/*.sql.zip` full dumps contain real customer data (file inventories, admin users and emails) and are git-ignored.
- The analyzer endpoint spends AI credits: set `WEBHOOK_SECRET` in production.

---

## Known gaps and next steps

- **Analyzer in the chain:** the processor calls the analyzer when `ANALYZER_URL` is set. Leave it unset in production until the analyzer has a hosted AI endpoint; locally, point it at `http://localhost:3002/api/analyze`.
- **Plugin versions:** SiteWitness reports no plugin versions, so the analyzer cannot tell a plugin update from tampered plugin files. Core files are already verified against the official wordpress.org checksums; with plugin versions, free plugins could be verified the same way (wordpress.org publishes per-version plugin checksums). Paid plugins and themes have no official checksums.
- **Analyzer in production:** local testing uses Ollama or the Claude Code bridge; a deployment needs a hosted AI endpoint and an API key. Check the Vercel plan allows the 300s `maxDuration`.
- **Changed-file collection auth:** the `/collect` route is authenticated only by the single-use `pull_nonce`. HMAC + timestamp signing (the `agent→site` direction) is the intended next layer before this is exposed beyond a trusted network.
- **Outdated subproject docs:** the woocommerce-agent README still describes the earlier Express + ngrok setup. (The SiteWitness plugin, agent, processor and analyzer READMEs, and the schema dump, are current with the `scan_reports` model.)
- **Legacy schema source:** `kleoshq_eventstore_api` still holds the original migrations; the dump in `stuff/db/` is the current reference.
