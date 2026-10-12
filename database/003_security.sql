-- =====================================================================
-- 003_security.sql
-- These tables hold lead PII. On Supabase every table in `public` is reachable
-- through its auto-generated REST API with the public anon key unless RLS is on.
-- RLS enabled + NO policies = anon/authenticated roles see nothing.
-- n8n connects with the direct Postgres connection string as the table OWNER
-- (e.g. `postgres`), which bypasses RLS - so workflows are unaffected.
-- If you later create a restricted role for n8n, grant it explicitly and add policies.
-- =====================================================================
BEGIN;

ALTER TABLE client_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE leads         ENABLE ROW LEVEL SECURITY;
ALTER TABLE llm_calls     ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings      ENABLE ROW LEVEL SECURITY;
ALTER TABLE events        ENABLE ROW LEVEL SECURITY;
ALTER TABLE schema_migrations ENABLE ROW LEVEL SECURITY;

-- Views run with the caller's permissions (Postgres 15+), so they cannot be used to read around RLS.
DO $$
BEGIN
  IF current_setting('server_version_num')::int >= 150000 THEN
    EXECUTE 'ALTER VIEW v_lead_sla       SET (security_invoker = true)';
    EXECUTE 'ALTER VIEW v_sla_summary    SET (security_invoker = true)';
    EXECUTE 'ALTER VIEW v_lead_timeline  SET (security_invoker = true)';
  END IF;
END $$;

INSERT INTO schema_migrations (version, description)
VALUES ('003', 'enable RLS on all tables; security_invoker views');

COMMIT;
