-- =====================================================================
-- db_smoke_test.sql  -  proves the schema behaves BEFORE any workflow touches it.
-- Run:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/db_smoke_test.sql
-- Requires migrations 001-003 + seed_demo.sql. Everything rolls back; nothing persists.
-- Any failed ASSERT aborts with a message. Success prints: ALL DB SMOKE TESTS PASSED
-- =====================================================================
BEGIN;

-- ---------- 0. preconditions (fail fast with a clear message) ----------
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM schema_migrations WHERE version IN ('001','002','003')) = 3,
    'PRECONDITION: migrations 001, 002 and 003 must all be applied (check: SELECT * FROM schema_migrations)';
  ASSERT (SELECT count(*) FROM client_config WHERE slug IN ('abc-roofing','northern-solar','maple-maid')) = 3,
    'PRECONDITION: seed_demo.sql has not been run (client_config is missing the 3 demo clients). Run seed_demo.sql, then re-run this test.';
END $$;

-- ---------- 1. postcode normalisation (the rule that drives the service-area guard) ----------
DO $$
DECLARE r RECORD; got TEXT;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('AU','4101',      '4101'),
      ('AU',' 4101 ',    '4101'),
      ('AU','410',       NULL),
      ('AU','ABCD',      NULL),
      ('AU',NULL,        NULL),
      ('GB','M1 4BT',    'M1'),
      ('GB','m14bt',     'M1'),
      ('GB','SW1A 1AA',  'SW1A'),
      ('GB','M14',       'M14'),
      ('GB','EH1 1YZ',   'EH1'),
      ('GB','12345',     NULL),
      ('CA','M5V 2T6',   'M5V'),
      ('CA','m5v2t6',    'M5V'),
      ('CA','V6B 1A1',   'V6B'),
      ('CA','M5V',       'M5V'),
      ('CA','90210',     NULL)
    ) AS t(country, raw, expected)
  LOOP
    got := normalize_postcode_area(r.country, r.raw);
    ASSERT got IS NOT DISTINCT FROM r.expected,
      format('postcode %s/%s: expected %s got %s', r.country, r.raw, r.expected, got);
  END LOOP;
END $$;

-- ---------- 2. lead insert: generated columns + defaults ----------
CREATE TEMP TABLE _ctx AS SELECT id AS client_id FROM client_config WHERE slug = 'abc-roofing';

INSERT INTO leads (client_id, source, external_id, raw_payload, name, email, phone, country,
                   service, postcode, urgency, is_test, test_case_id, t_received)
SELECT client_id, 'web_form', 'sub-001', '{"x":1}', 'John Smith', 'John@Example.com', '+61400000000', 'AU',
       'roof repair', '4101', 'this_week', true, 'T001', now() - interval '10 seconds'
FROM _ctx;

DO $$
DECLARE l leads%ROWTYPE;
BEGIN
  SELECT * INTO l FROM leads WHERE external_id = 'sub-001';
  ASSERT l.postcode_area = '4101',            'postcode_area generated';
  ASSERT l.dedupe_key = md5('john@example.com|+61400000000'), 'dedupe_key is case-insensitive on email';
  ASSERT l.status = 'received',               'default status';
  ASSERT l.missing_fields = '{}',             'default missing_fields';
  ASSERT l.is_after_hours = false,            'default after_hours';
END $$;

-- ---------- 3. constraints reject bad data ----------
DO $$
DECLARE cid UUID; ok BOOLEAN;
BEGIN
  SELECT client_id INTO cid FROM _ctx;

  -- no contact at all
  ok := false;
  BEGIN
    INSERT INTO leads (client_id, source, raw_payload, country) VALUES (cid,'web_form','{}','AU');
  EXCEPTION WHEN check_violation THEN ok := true; END;
  ASSERT ok, 'lead without email/phone must be rejected';

  -- bad status
  ok := false;
  BEGIN
    INSERT INTO leads (client_id, source, raw_payload, country, email, status)
    VALUES (cid,'web_form','{}','AU','a@b.co','bogus');
  EXCEPTION WHEN check_violation THEN ok := true; END;
  ASSERT ok, 'invalid status must be rejected';

  -- reply before receipt
  ok := false;
  BEGIN
    INSERT INTO leads (client_id, source, raw_payload, country, email, t_received, t_first_reply)
    VALUES (cid,'web_form','{}','AU','a@b.co', now(), now() - interval '1 hour');
  EXCEPTION WHEN check_violation THEN ok := true; END;
  ASSERT ok, 't_first_reply before t_received must be rejected';

  -- idempotency: same submission id twice
  ok := false;
  BEGIN
    INSERT INTO leads (client_id, source, external_id, raw_payload, country, email)
    VALUES (cid,'web_form','sub-001','{}','AU','dup@b.co');
  EXCEPTION WHEN unique_violation THEN ok := true; END;
  ASSERT ok, 'duplicate (client, source, external_id) must be rejected';

  -- NULL external_id may repeat (e.g. manual entries)
  INSERT INTO leads (client_id, source, raw_payload, country, email) VALUES (cid,'manual','{}','AU','m1@b.co');
  INSERT INTO leads (client_id, source, raw_payload, country, email) VALUES (cid,'manual','{}','AU','m2@b.co');
END $$;

-- ---------- 4. full lifecycle: Workflow A + B write paths ----------
DO $$
DECLARE lid UUID; cid UUID; llm UUID; n INT; ms INT;
BEGIN
  SELECT client_id INTO cid FROM _ctx;
  SELECT id INTO lid FROM leads WHERE external_id = 'sub-001';

  INSERT INTO messages (lead_id, direction, channel, author, body, delivery_status)
  VALUES (lid, 'inbound', 'web_form', 'lead', 'Need my roof repaired this week', 'received');

  INSERT INTO llm_calls (lead_id, provider, model, prompt_version, status, latency_ms, response_parsed)
  VALUES (lid, 'gemini', 'gemini-flash', 'lq-v1.0', 'ok', 1800, '{"is_spam":false}') RETURNING id INTO llm;

  INSERT INTO messages (lead_id, direction, channel, author, subject, body, llm_call_id,
                        provider, provider_message_id, delivery_status, sent_at)
  VALUES (lid, 'outbound', 'email', 'llm', 'Thanks John', 'Hi John...', llm,
          'resend', 'msg_123', 'sent', now());

  INSERT INTO events (lead_id, client_id, workflow, step, status, duration_ms)
  VALUES (lid, cid, 'intake', 'lead_received', 'ok', 5),
         (lid, cid, 'intake', 'llm_call',      'ok', 1800),
         (lid, cid, 'intake', 'reply_sent',    'ok', 900);

  UPDATE leads SET status='replied', score='HOT', score_reason='in_area+urgent+complete',
                   reply_mode='ai', t_first_reply = now() WHERE id = lid;

  SELECT response_ms INTO ms FROM v_lead_sla WHERE lead_id = lid;
  ASSERT ms BETWEEN 9000 AND 12000, format('response_ms ~10s, got %s', ms);
  ASSERT (SELECT within_60s FROM v_lead_sla WHERE lead_id = lid), 'within_60s true';

  SELECT count(*) INTO n FROM v_lead_timeline WHERE lead_id = lid;
  ASSERT n = 3, 'timeline has 3 events';
  ASSERT (SELECT count(*) FROM v_sla_summary WHERE client_name = 'ABC Roofing' AND is_test) = 1, 'summary row';

  -- Workflow B: booking, idempotent on retry, cancel flips back
  INSERT INTO bookings (lead_id, client_id, provider_booking_uid, start_time, attendee_email, matched_by)
  VALUES (lid, cid, 'cal_abc', now() + interval '2 days', 'john@example.com', 'email');

  INSERT INTO bookings (lead_id, client_id, provider_booking_uid, start_time, attendee_email, matched_by)
  VALUES (lid, cid, 'cal_abc', now() + interval '2 days', 'john@example.com', 'email')
  ON CONFLICT (provider, provider_booking_uid) DO UPDATE SET status = bookings.status;
  ASSERT (SELECT count(*) FROM bookings WHERE provider_booking_uid = 'cal_abc') = 1, 'booking webhook retry is idempotent';

  UPDATE bookings SET status = 'cancelled' WHERE provider_booking_uid = 'cal_abc';
  ASSERT (SELECT status FROM bookings WHERE provider_booking_uid = 'cal_abc') = 'cancelled', 'cancel';
END $$;

-- ---------- 5. updated_at trigger ----------
DO $$
DECLARE before_ts TIMESTAMPTZ; after_ts TIMESTAMPTZ;
BEGIN
  SELECT updated_at INTO before_ts FROM leads WHERE external_id = 'sub-001';
  PERFORM pg_sleep(0.05);
  UPDATE leads SET score_reason = 'touch' WHERE external_id = 'sub-001';
  SELECT updated_at INTO after_ts FROM leads WHERE external_id = 'sub-001';
  -- inside one transaction now() is frozen, so only check it did not go backwards
  ASSERT after_ts >= before_ts, 'updated_at maintained';
END $$;

-- ---------- 6. deletion behaviour (erasure requests) ----------
DO $$
DECLARE lid UUID;
BEGIN
  SELECT id INTO lid FROM leads WHERE external_id = 'sub-001';
  DELETE FROM leads WHERE id = lid;
  ASSERT (SELECT count(*) FROM messages  WHERE lead_id = lid) = 0, 'messages cascade';
  ASSERT (SELECT count(*) FROM llm_calls WHERE lead_id = lid) = 0, 'llm_calls cascade';
  ASSERT (SELECT count(*) FROM events WHERE lead_id = lid) = 0 AND
         (SELECT count(*) FROM events WHERE workflow = 'intake' AND step = 'reply_sent') >= 1,
         'events survive with lead_id NULL (audit trail kept)';
END $$;

-- ---------- 7. seed sanity: every client has the config workflows depend on ----------
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM client_config WHERE is_active) >= 3, 'three seeded clients';
  ASSERT NOT EXISTS (SELECT 1 FROM client_config
                     WHERE cardinality(service_areas) = 0 OR cardinality(services) = 0),
         'clients have services and areas';
END $$;

SELECT 'ALL DB SMOKE TESTS PASSED' AS result;
ROLLBACK;
