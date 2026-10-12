# Speed-to-Lead (PoC)

Inquiry arrives -> AI reply within 60 s -> qualified -> booked -> logged in CRM.
Stack: n8n (glue) · Postgres (source of truth) · Gemini Flash / Grok free tier (single-shot LLM call) · Cal.com · HubSpot Free · Telegram alerts.

**Postgres stores the state. n8n moves the state.**

## Repo layout

```
database/
  001_initial_schema.sql      tables, constraints, postcode function     (never edit once applied)
  002_indexes_and_views.sql   indexes + v_lead_sla / v_sla_summary / v_lead_timeline
  003_security.sql            RLS on (PII), security_invoker views
  seed_demo.sql               3 fictional clients: AU roofing, GB solar, CA cleaning
docs/contracts.md             state machine, guard + scoring rules, LLM contract, column write-map, metrics
prompts/lead-qualification.md prompt lq-v1.0 + JSON schema + post-call checks
tests/
  db_smoke_test.sql           schema assertions; rolls back; prints ALL DB SMOKE TESTS PASSED
  synthetic-leads.json        26 cases (T001-T026) with expected outcomes
n8n/                          exported workflow JSON goes here, one file per workflow
```

## Quick start (Phase 1)

```bash
export DATABASE_URL="postgresql://USER:PASS@HOST/DB?sslmode=require"   # Neon or Supabase direct connection
for f in database/001_initial_schema.sql database/002_indexes_and_views.sql \
         database/003_security.sql database/seed_demo.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/db_smoke_test.sql   # must print ALL DB SMOKE TESTS PASSED
```

Then edit the three `REPLACE_ME` values in `client_config` (booking URL, from/owner email, Telegram id). They are data, so use an `UPDATE`, not a new migration.

## Rules that keep the schema stable

1. **Contract -> migration -> workflow -> test**, in that order, one commit. Details: `docs/contracts.md` section 8.
2. In n8n Postgres nodes always use **Query Parameters** (`$1`, `$2`), never `{{ }}` inside the SQL text. Values with quotes will break (or exploit) interpolated SQL.
3. Each column has one writer (`contracts.md` section 6). If two nodes want to write the same column, you have a design problem, not a schema problem.
4. Connect n8n with the direct connection string and SSL on. If you hit prepared-statement errors on a pooled endpoint, switch to the direct/session connection.
5. Free LLM tiers get synthetic data only.

## Build order (each phase has an exit test; don't start the next until it passes)

After every phase: run `db_smoke_test.sql`, run the listed test cases, export the workflow JSON to `n8n/`, commit.

| # | Phase | Build | Exit test |
|---|---|---|---|
| 0 | Contracts | This repo | done |
| 1 | Database | Apply 001-003 + seed on Neon/Supabase | Smoke test passes on the hosted DB |
| 2 | **Workflow C - errors first** | Error Trigger -> insert `events (workflow='error', step='workflow_error', detail)` -> Telegram message to you. Set it as the error workflow on every later workflow. | Break a scratch node on purpose: one `events` row + one Telegram message |
| 3 | Workflow A v1 - intake -> DB | HTML form (generates `submission_id` UUID, disables the button after click) -> Webhook (respond 200 immediately) -> Normalize -> `INSERT ... ON CONFLICT (client_id, source, external_id) DO NOTHING RETURNING id` -> inbound message -> events | **T010**: two sends, one lead. Rows in `leads`, `messages`, `events` |
| 4 | A v2 - guards + scoring (no LLM) | spam, duplicate, area, after-hours flag, scoring per `contracts.md` section 3 | T003-T007, T011, T015, T020-T023: `leads` rows match expectations. T012 sets `is_after_hours` |
| 5 | A v3 - template reply, end to end | Send `fallback_subject/body` by email, set `t_first_reply`, `status='replied'`, outbound `messages` row. **First demo-able slice.** | T001 shows a number in `v_lead_sla`. T019: `failed` + Workflow C alert |
| 6 | A v4 - LLM replaces the template | HTTP Request -> validate -> merge -> `llm_calls` row -> reply. Fallback path stays. | T001, T002, T008, T009, T013, T014, T016, T017, T018 |
| 7 | Workflow B - booking | **Capture a real Cal.com webhook first** and replace the illustrative payloads in T024-T026. Webhook -> upsert `bookings` (`ON CONFLICT (provider, provider_booking_uid)`) -> lead status / `t_booked` | T024, T025, T026 |
| 8 | HubSpot sync | Upsert contact + deal, store `crm_*` ids; Workflow B moves the deal stage | Deal stage flips to Booked on T024; `crm_status='synced'` |
| 9 | Owner alerts | Telegram on HOT leads, silent when `is_after_hours`; booking confirmation | T001, T012, T024 alerts correct |
| 10 | Measure + ship | Run all 26 cases, then move n8n to an always-on host and record the demo | `v_sla_summary`: p50/p95, `pct_within_60s` for `is_test = true` |

## Checking a phase (copy/paste)

```sql
-- what happened to each test lead
SELECT test_case_id, status, score, reject_reason, postcode_area, is_after_hours,
       missing_fields, reply_mode, response_ms
FROM leads l LEFT JOIN v_lead_sla s ON s.lead_id = l.id
WHERE l.is_test ORDER BY test_case_id;

-- timeline for one lead (the demo screen)
SELECT step, status, ms_since_received FROM v_lead_timeline WHERE lead_id = '<uuid>';

-- headline numbers
SELECT * FROM v_sla_summary;

-- anything broken lately
SELECT ts, workflow, step, error FROM events WHERE status = 'fail' ORDER BY ts DESC LIMIT 20;
```

## Known limits (stated, not hidden)

- `response_ms` measures pipeline latency (webhook arrival -> email provider accepted). It excludes browser-to-webhook and provider-to-inbox time. Label it that way in the demo.
- The 24-hour duplicate check is a query, not a constraint. Two simultaneous submissions from the same person could both pass; the `submission_id` unique constraint covers the realistic double-click case. Fix, if it ever matters: an advisory lock keyed on `dedupe_key`.
- Cal.com webhook payloads in T024-T026 are illustrative until you replace them with captured ones.
- Not built (columns/hooks exist, nothing writes them): follow-up cadence, opt-out handling, inbound SMS/WhatsApp replies.
