-- ---------------------------------------------------------------------------
-- KleosHQ database: schema + reference data
--
-- Source: local kleoshq_development (PostgreSQL 17, pg_dump 17.10), generated 2026-10-08
--
-- Contains
--   - full public schema: tables, sequences, indexes, constraints, v_ingestions
--     (including the analyzer columns from kleoshq-ingestion-analyzer/sql/)
--   - reference rows: sources, schema_migrations, ar_internal_metadata,
--     events_projection_checkpoints
-- Does NOT contain
--   - ingestions, ingestions_log, events, events_processed_keys rows
--   - real webhook secrets: sources.webhook_secret is set to 'CHANGE_ME';
--     set the real value per environment (it must match the agent's config):
--       UPDATE public.sources SET webhook_secret = '<secret>' WHERE slug = 'pattyboop';
--   - owners / grants (--no-owner --no-acl): objects belong to the restoring user
--
-- TimescaleDB is installed on the local DB but no table is a hypertable, so the
-- extension is not required to restore this file.
--
-- Restore on an EMPTY database:
--   psql "<connection string>" -v ON_ERROR_STOP=1 -f kleoshq_schema_and_reference_20261008.sql
--   (or paste into the Neon SQL editor / TablePlus)
-- ---------------------------------------------------------------------------

--
-- PostgreSQL database dump
--

\restrict NpApfXa5fpZ87rgKmMxmbsFWKwbKodbYb3zhWQgRTufaJPKV6cIwNuesECrrM6m

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
    errors jsonb DEFAULT '{}'::jsonb NOT NULL,
    results jsonb DEFAULT '{}'::jsonb NOT NULL,
    analyzed_at timestamp with time zone,
    analysis_results jsonb DEFAULT '{}'::jsonb NOT NULL,
    analysis_status character varying,
    analysis_certainty integer,
    CONSTRAINT ingestions_analysis_certainty_check CHECK (((analysis_certainty IS NULL) OR ((analysis_certainty >= 0) AND (analysis_certainty <= 100)))),
    CONSTRAINT ingestions_analysis_status_check CHECK (((analysis_status IS NULL) OR ((analysis_status)::text = ANY ((ARRAY['legit'::character varying, 'malicious'::character varying, 'unknown'::character varying])::text[]))))
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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id bigint DEFAULT nextval('public.sources_id_seq'::regclass) NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone NOT NULL,
    name character varying NOT NULL,
    platform character varying NOT NULL,
    slug character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    webhook_secret character varying NOT NULL
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
    errors,
    results,
    analyzed_at,
    analysis_status,
    analysis_certainty,
    analysis_results
   FROM public.ingestions
  ORDER BY id;


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
-- Name: index_ingestions_pending_analysis; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestions_pending_analysis ON public.ingestions USING btree (source_id, ingested_at) WHERE ((analyzed_at IS NULL) AND ((status)::text = 'processed'::text) AND ((event_type)::text = 'sitewitness_report'::text));


--
-- Name: index_sources_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sources_on_active ON public.sources USING btree (active);


--
-- Name: index_sources_on_platform; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sources_on_platform ON public.sources USING btree (platform);


--
-- Name: index_sources_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sources_on_slug ON public.sources USING btree (slug);


--
-- Name: uq_events_processed_keys; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_events_processed_keys ON public.events_processed_keys USING btree (source_id, idempotency_key);


--
-- PostgreSQL database dump complete
--

\unrestrict NpApfXa5fpZ87rgKmMxmbsFWKwbKodbYb3zhWQgRTufaJPKV6cIwNuesECrrM6m


-- ===========================================================================
-- REFERENCE DATA
-- ===========================================================================
--
-- PostgreSQL database dump
--

\restrict NnMY7HS5YeDAvwgF8VowS0ttjhiCEwcdOeEOpDwppfESzgGKnBjVgmpMWAhpNlo

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
-- Data for Name: sources; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.sources (id, active, created_at, name, platform, slug, updated_at, webhook_secret) VALUES (1, true, '2026-04-29 12:35:33.320553', 'PattyBoop Fashion Store', 'woocommerce', 'pattyboop', '2026-04-29 12:35:33.320553', 'CHANGE_ME');


--
-- PostgreSQL database dump complete
--

\unrestrict NnMY7HS5YeDAvwgF8VowS0ttjhiCEwcdOeEOpDwppfESzgGKnBjVgmpMWAhpNlo


--
-- Sequences of the reference tables: continue after the restored rows
--

SELECT pg_catalog.setval('public.sources_id_seq', COALESCE((SELECT max(id) FROM public.sources), 1), (SELECT count(*) > 0 FROM public.sources));
SELECT pg_catalog.setval('public.events_projection_checkpoints_id_seq', COALESCE((SELECT max(id) FROM public.events_projection_checkpoints), 1), (SELECT count(*) > 0 FROM public.events_projection_checkpoints));
