-- ---------------------------------------------------------------------------
-- KleosHQ database: schema + reference data
--
-- Source: local kleoshq_development (PostgreSQL 17, pg_dump 17.10), generated 2026-10-22,
--         with migrations stuff/db/migrations/0002 … 0011 applied (incl. incidents,
--         incident_remediation_steps, sources.reporting_email, verdict
--         legit | malicious | suspicious).
--
-- A database restored from THIS file is already at migration 0011: do not run
-- migrations 0002–0011 on it. Run only migrations numbered above 0011.
--
-- Contains
--   - full public schema: tables, sequences, indexes, constraints, v_ingestions,
--     uuidv7(), incidents + incident_remediation_steps, scan_reports
--   - reference rows: schema_migrations, ar_internal_metadata,
--     events_projection_checkpoints, and the channel catalogue (curated rows from
--     kleoshq-public-www/supabase/seed_channels.sql, NOT copied from the local DB)
-- Does NOT contain
--   - ingestions, ingestions_log, events, events_processed_keys, scan_reports,
--     incidents rows
--   - websites / sources rows (they hold user data and HMAC secrets): copy them
--     with stuff/db/scripts/export_supabase_app_tables.mjs or create them in the app
--   - login roles / owners / grants (--no-owner --no-acl): objects belong to the
--     restoring user
--
-- TimescaleDB is installed on the local DB but no table is a hypertable, so the
-- extension is not required to restore this file.
--
-- Restore on an EMPTY database:
--   psql "<connection string>" -v ON_ERROR_STOP=1 -f kleoshq_schema_and_reference_20261022.sql
--   (or paste into the Neon SQL editor / TablePlus)
-- ---------------------------------------------------------------------------

--
-- PostgreSQL database dump
--

\restrict t6CpOJequxJD6YVsZhdKUhuMVhTDa65BmIU4I3csvMfzh2XQFfbsDXNsAvlpBMq

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: uuidv7(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.uuidv7() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    icon text DEFAULT ''::text NOT NULL,
    webhook_url text DEFAULT ''::text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    aggregate_id bigint,
    aggregate_type text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    event_type text NOT NULL,
    id bigint DEFAULT nextval('public.events_id_seq'::regclass) NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    payload_hash text NOT NULL,
    source_id uuid NOT NULL
);


--
-- Name: events_processed_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.events_processed_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: events_processed_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_processed_keys (
    id bigint DEFAULT nextval('public.events_processed_keys_id_seq'::regclass) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    idempotency_key character varying NOT NULL,
    source_id uuid NOT NULL,
    event_id bigint NOT NULL
);


--
-- Name: events_projection_checkpoints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.events_projection_checkpoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: events_projection_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_projection_checkpoints (
    id bigint DEFAULT nextval('public.events_projection_checkpoints_id_seq'::regclass) NOT NULL,
    created_at timestamp without time zone NOT NULL,
    last_position bigint DEFAULT 0 NOT NULL,
    projection_name character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: incident_remediation_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incident_remediation_steps (
    id uuid DEFAULT public.uuidv7() NOT NULL,
    incident_id uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    file_path text,
    instruction text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    verification text,
    priority text DEFAULT 'medium'::text NOT NULL,
    CONSTRAINT incident_remediation_steps_priority_check CHECK ((priority = ANY (ARRAY['critical'::text, 'urgent'::text, 'medium'::text, 'low'::text])))
);


--
-- Name: incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidents (
    id uuid DEFAULT public.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    source_id uuid NOT NULL,
    scan_report_id uuid,
    status text DEFAULT 'open'::text NOT NULL,
    summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    close_comment text,
    CONSTRAINT incidents_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text])))
);


--
-- Name: ingestions_id_seq1; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ingestions_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ingestions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingestions (
    id bigint DEFAULT nextval('public.ingestions_id_seq1'::regclass) NOT NULL,
    site_identifier character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    event_type character varying,
    ingested_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    payload text NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    source_id uuid,
    errors jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: ingestions_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingestions_log (
    id bigint NOT NULL,
    site_identifier character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    event_type character varying,
    ingested_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    source_id uuid
);


--
-- Name: ingestions_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ingestions_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ingestions_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ingestions_log_id_seq OWNED BY public.ingestions_log.id;


--
-- Name: scan_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scan_reports (
    id uuid DEFAULT public.uuidv7() NOT NULL,
    ingestion_id bigint,
    source_id uuid,
    site_identifier character varying,
    event_type character varying,
    results jsonb DEFAULT '{}'::jsonb NOT NULL,
    analyzed_at timestamp with time zone,
    analysis_results jsonb DEFAULT '{}'::jsonb NOT NULL,
    analysis_status character varying,
    analysis_certainty integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT scan_reports_analysis_certainty_check CHECK (((analysis_certainty IS NULL) OR ((analysis_certainty >= 0) AND (analysis_certainty <= 100)))),
    CONSTRAINT scan_reports_analysis_status_check CHECK (((analysis_status IS NULL) OR ((analysis_status)::text = ANY ((ARRAY['legit'::character varying, 'malicious'::character varying, 'suspicious'::character varying])::text[]))))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    website_id uuid,
    channel_code text NOT NULL,
    name text NOT NULL,
    hmac text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    status text DEFAULT 'not scanned yet'::text NOT NULL,
    status_changed_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reporting_email text,
    CONSTRAINT sources_status_check CHECK ((status = ANY (ARRAY['healthy'::text, 'warning'::text, 'compromised'::text, 'not scanned yet'::text, 'awaiting_verification'::text])))
);


--
-- Name: v_ingestions; Type: VIEW; Schema: public; Owner: -
--

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


--
-- Name: websites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.websites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    url text NOT NULL,
    slug text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingestions_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestions_log ALTER COLUMN id SET DEFAULT nextval('public.ingestions_log_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: channels channels_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_code_key UNIQUE (code);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id, created_at);


--
-- Name: events_processed_keys events_processed_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_processed_keys
    ADD CONSTRAINT events_processed_keys_pkey PRIMARY KEY (id);


--
-- Name: events_projection_checkpoints events_projection_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_projection_checkpoints
    ADD CONSTRAINT events_projection_checkpoints_pkey PRIMARY KEY (id);


--
-- Name: incident_remediation_steps incident_remediation_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incident_remediation_steps
    ADD CONSTRAINT incident_remediation_steps_pkey PRIMARY KEY (id);


--
-- Name: incidents incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_pkey PRIMARY KEY (id);


--
-- Name: incidents incidents_scan_report_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_scan_report_unique UNIQUE (scan_report_id);


--
-- Name: ingestions_log ingestions_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestions_log
    ADD CONSTRAINT ingestions_log_pkey PRIMARY KEY (id);


--
-- Name: ingestions ingestions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestions
    ADD CONSTRAINT ingestions_pkey PRIMARY KEY (id);


--
-- Name: scan_reports scan_reports_ingestion_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scan_reports
    ADD CONSTRAINT scan_reports_ingestion_id_key UNIQUE (ingestion_id);


--
-- Name: scan_reports scan_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scan_reports
    ADD CONSTRAINT scan_reports_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);


--
-- Name: sources sources_website_channel_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_website_channel_unique UNIQUE (website_id, channel_code);


--
-- Name: websites websites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.websites
    ADD CONSTRAINT websites_pkey PRIMARY KEY (id);


--
-- Name: websites websites_slug_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.websites
    ADD CONSTRAINT websites_slug_unique UNIQUE (slug);


--
-- Name: websites websites_url_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.websites
    ADD CONSTRAINT websites_url_unique UNIQUE (url);


--
-- Name: events_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX events_created_at_idx ON public.events USING btree (created_at DESC);


--
-- Name: events_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX events_id_unique ON public.events USING btree (id);


--
-- Name: idx_events_entity_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_entity_history ON public.events USING btree (source_id, aggregate_type, aggregate_id, created_at);


--
-- Name: idx_events_payload_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_payload_hash ON public.events USING btree (payload_hash, created_at);


--
-- Name: idx_events_source_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_source_time ON public.events USING btree (source_id, created_at);


--
-- Name: idx_events_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_type_time ON public.events USING btree (event_type, created_at);


--
-- Name: incident_steps_incident_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX incident_steps_incident_id_idx ON public.incident_remediation_steps USING btree (incident_id, "position");


--
-- Name: incidents_source_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX incidents_source_id_idx ON public.incidents USING btree (source_id);


--
-- Name: incidents_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX incidents_user_id_idx ON public.incidents USING btree (user_id);


--
-- Name: index_events_projection_checkpoints_on_projection_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_projection_checkpoints_on_projection_name ON public.events_projection_checkpoints USING btree (projection_name);


--
-- Name: index_ingestions_log_on_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_log_on_event_type ON public.ingestions_log USING btree (event_type);


--
-- Name: index_ingestions_log_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_log_on_idempotency_key ON public.ingestions_log USING btree (idempotency_key);


--
-- Name: index_ingestions_log_on_ingested_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_log_on_ingested_at ON public.ingestions_log USING btree (ingested_at);


--
-- Name: index_ingestions_log_on_site_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_log_on_site_identifier ON public.ingestions_log USING btree (site_identifier);


--
-- Name: index_ingestions_log_on_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_log_on_source_id ON public.ingestions_log USING btree (source_id);


--
-- Name: index_ingestions_on_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_on_event_type ON public.ingestions USING btree (event_type);


--
-- Name: index_ingestions_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ingestions_on_idempotency_key ON public.ingestions USING btree (idempotency_key);


--
-- Name: index_ingestions_on_ingested_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_on_ingested_at ON public.ingestions USING btree (ingested_at);


--
-- Name: index_ingestions_on_site_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_on_site_identifier ON public.ingestions USING btree (site_identifier);


--
-- Name: index_ingestions_on_site_source_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ingestions_on_site_source_idempotency ON public.ingestions USING btree (site_identifier, source_id, idempotency_key);


--
-- Name: index_ingestions_on_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_on_source_id ON public.ingestions USING btree (source_id);


--
-- Name: index_ingestions_on_source_type_status_ingested_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_on_source_type_status_ingested_at ON public.ingestions USING btree (source_id, event_type, status, ingested_at);


--
-- Name: scan_reports_pending_analysis_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scan_reports_pending_analysis_idx ON public.scan_reports USING btree (source_id, created_at) WHERE (analyzed_at IS NULL);


--
-- Name: scan_reports_source_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scan_reports_source_id_idx ON public.scan_reports USING btree (source_id);


--
-- Name: sources_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sources_user_id_idx ON public.sources USING btree (user_id);


--
-- Name: uq_events_processed_keys; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_events_processed_keys ON public.events_processed_keys USING btree (source_id, idempotency_key);


--
-- Name: websites_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX websites_user_id_idx ON public.websites USING btree (user_id);


--
-- Name: incident_remediation_steps incident_remediation_steps_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incident_remediation_steps
    ADD CONSTRAINT incident_remediation_steps_incident_id_fkey FOREIGN KEY (incident_id) REFERENCES public.incidents(id) ON DELETE CASCADE;


--
-- Name: incidents incidents_scan_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_scan_report_id_fkey FOREIGN KEY (scan_report_id) REFERENCES public.scan_reports(id) ON DELETE SET NULL;


--
-- Name: incidents incidents_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE CASCADE;


--
-- Name: scan_reports scan_reports_ingestion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scan_reports
    ADD CONSTRAINT scan_reports_ingestion_id_fkey FOREIGN KEY (ingestion_id) REFERENCES public.ingestions(id) ON DELETE SET NULL;


--
-- Name: sources sources_channel_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_channel_code_fkey FOREIGN KEY (channel_code) REFERENCES public.channels(code) ON DELETE RESTRICT;


--
-- Name: sources sources_website_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_website_id_fkey FOREIGN KEY (website_id) REFERENCES public.websites(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict t6CpOJequxJD6YVsZhdKUhuMVhTDa65BmIU4I3csvMfzh2XQFfbsDXNsAvlpBMq

--
-- PostgreSQL database dump
--

\restrict RcMVWtSS3ef9HIeLNCulcLDPvPvehra8EhKSb8DkCGec10A0n7FUMQSI53nuBrH

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: ar_internal_metadata; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.ar_internal_metadata (key, value, created_at, updated_at) VALUES ('environment', 'development', '2026-04-29 12:34:33.937304', '2026-04-29 12:34:33.937311');
INSERT INTO public.ar_internal_metadata (key, value, created_at, updated_at) VALUES ('schema_sha1', '4f8eb314f8175dbe5b9c81edb4c7a08e2898c06a', '2026-04-29 12:34:34.130962', '2026-04-29 12:34:34.13097');


--
-- Data for Name: channels; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: events_projection_checkpoints; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: schema_migrations; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.schema_migrations (version) VALUES ('20260427113227');
INSERT INTO public.schema_migrations (version) VALUES ('20260427113228');
INSERT INTO public.schema_migrations (version) VALUES ('20260427113229');
INSERT INTO public.schema_migrations (version) VALUES ('20260427113230');
INSERT INTO public.schema_migrations (version) VALUES ('20260504163616');


--
-- PostgreSQL database dump complete
--

\unrestrict RcMVWtSS3ef9HIeLNCulcLDPvPvehra8EhKSb8DkCGec10A0n7FUMQSI53nuBrH

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
