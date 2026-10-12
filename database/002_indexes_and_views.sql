-- =====================================================================
-- 002_indexes_and_views.sql
-- Indexes serve the exact queries the workflows run (named in comments).
-- Views are the demo/metrics layer: safe to DROP/CREATE later without touching data.
-- =====================================================================
BEGIN;

-- Workflow A: dedupe lookup  (same person, same client, recent)
CREATE INDEX idx_leads_dedupe        ON leads (client_id, dedupe_key, t_received DESC);
-- Workflow B: match a booking to a lead by attendee email
CREATE INDEX idx_leads_email         ON leads (client_id, lower(email));
-- Ops: recent leads per client, stuck leads
CREATE INDEX idx_leads_client_recent ON leads (client_id, created_at DESC);
CREATE INDEX idx_leads_open_status   ON leads (status) WHERE status IN ('received','processing');
-- Phase 2 follow-ups
CREATE INDEX idx_leads_followup      ON leads (next_followup_at) WHERE next_followup_at IS NOT NULL;
-- Real vs synthetic separation for reporting
CREATE INDEX idx_leads_test          ON leads (is_test, test_case_id);

CREATE INDEX idx_messages_lead       ON messages (lead_id, ts);
-- Delivery-status webhooks look messages up by provider id
CREATE UNIQUE INDEX uq_messages_provider_id
  ON messages (provider, provider_message_id) WHERE provider_message_id IS NOT NULL;

CREATE INDEX idx_llm_calls_lead      ON llm_calls (lead_id, created_at);
CREATE INDEX idx_llm_calls_model     ON llm_calls (provider, model, created_at DESC);

CREATE INDEX idx_bookings_lead       ON bookings (lead_id);

CREATE INDEX idx_events_lead         ON events (lead_id, ts);
CREATE INDEX idx_events_failures     ON events (ts DESC) WHERE status = 'fail';

-- ---------------------------------------------------------------------
-- v_lead_sla: one row per lead with its speed-to-lead number
-- ---------------------------------------------------------------------
CREATE VIEW v_lead_sla AS
SELECT l.id               AS lead_id,
       c.client_name,
       l.test_case_id,
       l.is_test,
       l.source,
       l.score,
       l.status,
       l.reply_mode,
       l.is_after_hours,
       l.t_received,
       l.t_first_reply,
       round(EXTRACT(EPOCH FROM (l.t_first_reply - l.t_received)) * 1000)::int AS response_ms,
       (l.t_first_reply - l.t_received) <= interval '60 seconds'               AS within_60s
FROM leads l
JOIN client_config c ON c.id = l.client_id;

-- ---------------------------------------------------------------------
-- v_sla_summary: the headline numbers (real leads only; filter is_test as needed)
-- ---------------------------------------------------------------------
CREATE VIEW v_sla_summary AS
SELECT client_name,
       is_test,
       count(*)                                                           AS leads,
       count(response_ms)                                                 AS replied,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY response_ms))   AS p50_ms,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY response_ms))   AS p95_ms,
       max(response_ms)                                                   AS max_ms,
       round(100.0 * count(*) FILTER (WHERE within_60s) / NULLIF(count(response_ms), 0), 1) AS pct_within_60s
FROM v_lead_sla
GROUP BY client_name, is_test;

-- ---------------------------------------------------------------------
-- v_lead_timeline: per-step offsets from t_received  (the "Screen 2" demo view)
-- ---------------------------------------------------------------------
CREATE VIEW v_lead_timeline AS
SELECT e.lead_id,
       e.workflow,
       e.step,
       e.status,
       e.duration_ms,
       round(EXTRACT(EPOCH FROM (e.ts - l.t_received)) * 1000)::int AS ms_since_received,
       e.error,
       e.ts
FROM events e
JOIN leads l ON l.id = e.lead_id
ORDER BY e.lead_id, e.ts, e.id;

INSERT INTO schema_migrations (version, description)
VALUES ('002', 'indexes + views: v_lead_sla, v_sla_summary, v_lead_timeline');

COMMIT;
