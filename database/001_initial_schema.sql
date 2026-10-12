-- =====================================================================
-- 001_initial_schema.sql  -  Speed-to-Lead PoC
-- Postgres 14+ (Neon / Supabase / local). Run ONCE on an empty database.
-- RULE: after this is applied anywhere, never edit it. A change = a new numbered file.
--
-- Design goal: every column any workflow (A intake, B booking, C errors)
-- or any metric will need is here, so building workflows does not force ALTERs.
-- Escape hatches for the unforeseen: client_config.settings, leads.meta (JSONB).
-- =====================================================================
BEGIN;

-- ---------- migration ledger ----------
CREATE TABLE schema_migrations (
  version     TEXT PRIMARY KEY,
  description TEXT NOT NULL,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- helpers ----------
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

-- Postcode -> "area key" used for service-area matching. One rule, one place.
--   AU: 4 digits                      '4101'      -> '4101'
--   GB: outward code                  'M1 4BT'    -> 'M1'   (also 'm14bt' -> 'M1')
--   CA: forward sortation area (FSA)  'm5v 2t6'   -> 'M5V'
-- Returns NULL when the input is not a valid postcode for that country.
CREATE FUNCTION normalize_postcode_area(p_country TEXT, p_raw TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_country
    WHEN 'AU' THEN CASE WHEN v ~ '^[0-9]{4}$' THEN v END
    WHEN 'CA' THEN CASE WHEN v ~ '^[A-Z][0-9][A-Z]([0-9][A-Z][0-9])?$' THEN left(v, 3) END
    WHEN 'GB' THEN CASE WHEN v ~ '^[A-Z]{1,2}[0-9][0-9A-Z]?([0-9][A-Z]{2})?$'
                        THEN CASE WHEN length(v) >= 5 THEN left(v, length(v) - 3) ELSE v END
                   END
  END
  FROM (SELECT upper(regexp_replace(coalesce(p_raw, ''), '[^A-Za-z0-9]', '', 'g')) AS v) s
$$;

-- ---------- client_config: how one business operates (config is DATA) ----------
CREATE TABLE client_config (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug               TEXT NOT NULL UNIQUE,
  client_name        TEXT NOT NULL,
  industry           TEXT NOT NULL,
  country            TEXT NOT NULL CHECK (country IN ('AU','GB','CA')),   -- ISO codes; GB = UK
  timezone           TEXT NOT NULL,                                       -- IANA, e.g. Australia/Brisbane
  services           TEXT[] NOT NULL,
  service_areas      TEXT[] NOT NULL,                                     -- postcode AREA KEYS (see normalize_postcode_area)
  required_fields    TEXT[] NOT NULL DEFAULT ARRAY['service','postcode','urgency'],  -- needed for HOT
  hot_urgencies      TEXT[] NOT NULL DEFAULT ARRAY['emergency','this_week'],
  business_hours     JSONB  NOT NULL,   -- {"mon":[["08:00","17:00"]],"sat":[],...} local time; [] = closed
  tone               TEXT NOT NULL DEFAULT 'professional and friendly',
  reply_signature    TEXT NOT NULL,
  after_hours_note   TEXT,              -- appended to the reply when is_after_hours
  booking_url        TEXT NOT NULL,
  from_name          TEXT,
  from_email         TEXT,
  owner_email        TEXT,
  owner_telegram_id  TEXT,
  fallback_subject   TEXT NOT NULL,     -- template vars: {{name}} {{service}} {{booking_url}} {{client_name}}
  fallback_body      TEXT NOT NULL,
  crm_config         JSONB NOT NULL DEFAULT '{}',   -- {"provider":"hubspot","pipeline_id":..,"stages":{"new":..,"booked":..}}
  settings           JSONB NOT NULL DEFAULT '{}',   -- escape hatch: avoid ALTERs for per-client oddities
  is_active          BOOLEAN NOT NULL DEFAULT true,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_client_config_updated BEFORE UPDATE ON client_config
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- leads: one row = one inquiry ----------
CREATE TABLE leads (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id        UUID NOT NULL REFERENCES client_config(id) ON DELETE RESTRICT,
  source           TEXT NOT NULL CHECK (source IN
                     ('web_form','email_forward','missed_call','facebook_lead','api','manual')),
  external_id      TEXT,                          -- idempotency key (form submission_id / email Message-ID)
  raw_payload      JSONB NOT NULL,
  is_test          BOOLEAN NOT NULL DEFAULT false,
  test_case_id     TEXT,                          -- 'T001'... ties a row to tests/synthetic-leads.json

  -- contact (set at intake)
  name             TEXT,
  email            TEXT,
  phone            TEXT,                          -- E.164
  country          TEXT NOT NULL CHECK (country IN ('AU','GB','CA')),   -- copied from client at intake

  -- qualification fields (from form at intake; LLM may fill gaps)
  service          TEXT,
  postcode         TEXT,                          -- as entered, cleaned
  postcode_area    TEXT GENERATED ALWAYS AS (normalize_postcode_area(country, postcode)) STORED,
  urgency          TEXT CHECK (urgency IN ('emergency','this_week','flexible','unknown')),
  property_type    TEXT,
  missing_fields   TEXT[] NOT NULL DEFAULT '{}',

  -- derived
  dedupe_key       TEXT GENERATED ALWAYS AS
                     (md5(lower(coalesce(email,'')) || '|' || coalesce(phone,''))) STORED,
  duplicate_of     UUID REFERENCES leads(id) ON DELETE SET NULL,

  -- decision state
  status           TEXT NOT NULL DEFAULT 'received'
                     CHECK (status IN ('received','processing','replied','booked','rejected','failed')),
  score            TEXT CHECK (score IN ('HOT','WARM','COLD')),
  score_reason     TEXT,                          -- deterministic explanation, e.g. 'in_area+urgent+complete'
  reject_reason    TEXT CHECK (reject_reason IN
                     ('spam','out_of_area','out_of_scope','duplicate','invalid','suppressed')),
  is_after_hours   BOOLEAN NOT NULL DEFAULT false,  -- after-hours is NOT a rejection; it changes the reply
  reply_mode       TEXT CHECK (reply_mode IN ('ai','fallback','none')),

  -- consent / follow-up hooks
  do_not_contact   BOOLEAN NOT NULL DEFAULT false,
  opted_out_at     TIMESTAMPTZ,
  followup_count   INT NOT NULL DEFAULT 0,
  next_followup_at TIMESTAMPTZ,

  -- speed-to-lead clock (exact definitions: docs/contracts.md section 6)
  t_received       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),  -- n8n overrides with webhook-arrival time
  t_first_reply    TIMESTAMPTZ,
  t_booked         TIMESTAMPTZ,

  -- CRM sync
  crm_provider     TEXT,
  crm_contact_id   TEXT,
  crm_deal_id      TEXT,
  crm_status       TEXT CHECK (crm_status IN ('pending','synced','failed')),
  crm_synced_at    TIMESTAMPTZ,

  meta             JSONB NOT NULL DEFAULT '{}',   -- escape hatch
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT leads_has_contact   CHECK (email IS NOT NULL OR phone IS NOT NULL),
  CONSTRAINT leads_reply_after   CHECK (t_first_reply IS NULL OR t_first_reply >= t_received),
  CONSTRAINT leads_idempotency   UNIQUE (client_id, source, external_id)   -- NULLs allowed multiple times
);
CREATE TRIGGER trg_leads_updated BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- llm_calls: every model call (debugging + model comparison) ----------
CREATE TABLE llm_calls (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id            UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  provider           TEXT NOT NULL,               -- 'gemini','xai',...
  model              TEXT NOT NULL,
  prompt_version     TEXT NOT NULL,               -- e.g. 'lq-v1.0' (prompts/lead-qualification.md)
  purpose            TEXT NOT NULL DEFAULT 'qualify_reply',
  status             TEXT NOT NULL CHECK (status IN
                       ('ok','invalid_json','schema_violation','timeout','rate_limited','error')),
  response_raw       TEXT,
  response_parsed    JSONB,
  validation_errors  TEXT[],
  error              TEXT,
  latency_ms         INT,
  tokens_in          INT,
  tokens_out         INT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ---------- messages: the conversation ----------
CREATE TABLE messages (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id               UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  direction             TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  channel               TEXT NOT NULL CHECK (channel IN ('web_form','email','sms','whatsapp','voice')),
  author                TEXT NOT NULL CHECK (author IN ('lead','llm','template','human')),
  subject               TEXT,
  body                  TEXT NOT NULL,
  llm_call_id           UUID REFERENCES llm_calls(id) ON DELETE SET NULL,
  provider              TEXT,                      -- 'resend','gmail','twilio'
  provider_message_id   TEXT,
  delivery_status       TEXT CHECK (delivery_status IN
                          ('received','queued','sent','delivered','failed','bounced')),
  delivery_error        TEXT,
  sent_at               TIMESTAMPTZ,               -- provider accepted the send
  delivered_at          TIMESTAMPTZ,               -- provider delivery webhook (when available)
  meta                  JSONB NOT NULL DEFAULT '{}',
  ts                    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ---------- bookings: Workflow B (reschedule/cancel need their own rows) ----------
CREATE TABLE bookings (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id               UUID REFERENCES leads(id) ON DELETE SET NULL,   -- NULL = could not match a lead
  client_id             UUID NOT NULL REFERENCES client_config(id) ON DELETE RESTRICT,
  provider              TEXT NOT NULL DEFAULT 'calcom',
  provider_booking_uid  TEXT NOT NULL,
  status                TEXT NOT NULL DEFAULT 'created'
                          CHECK (status IN ('created','rescheduled','cancelled','completed','no_show')),
  start_time            TIMESTAMPTZ,
  end_time              TIMESTAMPTZ,
  attendee_name         TEXT,
  attendee_email        TEXT,
  event_type            TEXT,
  matched_by            TEXT CHECK (matched_by IN ('metadata','email','phone','manual')),
  payload               JSONB NOT NULL DEFAULT '{}',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT bookings_idempotency UNIQUE (provider, provider_booking_uid)  -- webhook retries are safe
);
CREATE TRIGGER trg_bookings_updated BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- events: audit + debugging + the demo timeline ----------
CREATE TABLE events (
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lead_id            UUID REFERENCES leads(id) ON DELETE SET NULL,   -- NULL for pre-lead / system errors
  client_id          UUID REFERENCES client_config(id) ON DELETE SET NULL,
  workflow           TEXT NOT NULL CHECK (workflow IN ('intake','booking','error','system')),
  step               TEXT NOT NULL,        -- vocabulary in docs/contracts.md section 4 (free text on purpose)
  status             TEXT NOT NULL CHECK (status IN ('ok','skip','warn','fail')),
  duration_ms        INT,
  error              TEXT,
  detail             JSONB NOT NULL DEFAULT '{}',
  n8n_execution_id   TEXT,
  ts                 TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO schema_migrations (version, description)
VALUES ('001', 'initial schema: client_config, leads, llm_calls, messages, bookings, events');

COMMIT;
