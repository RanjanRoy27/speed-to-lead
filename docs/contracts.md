# Data contracts

Three contracts, one source of truth. If something here changes, **change the contract first, then the migration, then the workflow, then the tests** - in that order, in one commit.

| Contract | Lives in | Consumers |
|---|---|---|
| Database schema | `database/*.sql` | Workflows A, B, C |
| Lead object (n8n internal) | section 2 | Workflow A |
| LLM output | `prompts/lead-qualification.md` + section 3 | Workflow A |

---

## 1. Lead state machine

```
                       ┌──────────► rejected   (spam | out_of_area | out_of_scope | duplicate | invalid)
received ─► processing ┤
                       ├──────────► failed     (send failed after retries; Workflow C alerts)
                       └─► replied ─► booked ─► replied   (booking cancelled flips back)
```

| Transition | Written by | When |
|---|---|---|
| (insert) → `received` | A / lead_inserted | row created |
| `received` → `rejected` | A / guard_* or llm_validate | guard or LLM says no reply; `reject_reason` set, `score = COLD` |
| `received` → `processing` | A / guards passed | before the LLM call |
| `processing` → `replied` | A / reply_sent | provider accepted the send; `t_first_reply` set |
| `processing` → `failed` | A / reply_sent (fail) or C | send failed; error event written |
| `replied` → `booked` | B / booking_saved | booking `created`; `t_booked` set |
| `booked` → `replied` | B / booking_saved | booking `cancelled` and no other active booking |

After-hours is **not** a rejection. The whole point is to reply when nobody is at the desk. It sets `is_after_hours = true`, appends `client_config.after_hours_note` to the reply, and the owner alert is sent silently.

## 2. Lead object (inside n8n, after the Normalize node)

```json
{
  "lead_id": null,
  "client_id": "uuid from client_config",
  "source": "web_form",
  "external_id": "submission_id from the form (UUID generated in the browser)",
  "t_received": "ISO timestamp taken in the first node after the webhook",
  "name": "John Smith",
  "email": "john@example.com",
  "phone": "+61400000000",
  "service": "roof repair",
  "postcode": "4101",
  "urgency": "this_week",
  "property_type": "house",
  "message": "free text",
  "honeypot": "",
  "is_test": false,
  "test_case_id": null,
  "raw_payload": {}
}
```

Normalize rules: email lowercased and trimmed; phone to E.164 using the client's country (null if unparseable); postcode trimmed (the DB derives `postcode_area`); urgency mapped to `emergency | this_week | flexible | unknown`; message truncated to 4,000 characters **for the LLM only** (the full text is kept in `raw_payload`).

## 3. Guard and scoring rules (all deterministic, all before/independent of the LLM)

Guard order (stop at the first hit; every guard writes an event):

1. **Idempotency** - `INSERT ... ON CONFLICT (client_id, source, external_id) DO NOTHING RETURNING id`. No row returned -> log `idempotent_skip`, stop. No reply, no second lead.
2. **Spam (deterministic)** - honeypot field filled, more than 2 URLs in the message, or a keyword blocklist hit -> `rejected / spam`.
3. **Duplicate person** - same `client_id` + `dedupe_key` in the last 24 hours on a non-rejected lead -> `rejected / duplicate`, set `duplicate_of`, append the new text as an inbound message on the original lead, no reply.
4. **Service area** - `postcode_area` not NULL and not in `service_areas` -> `rejected / out_of_area`. `postcode_area` NULL (missing or invalid) is **not** a rejection: it adds `postcode` to `missing_fields`.
5. **After-hours flag** - evaluate `t_received` in the client's timezone against `business_hours`; set `is_after_hours`. Never rejects. When `is_test = true`, the clock may be overridden by `raw_payload._test.clock_local` so the test suite doesn't depend on the time of day (`t_received` itself stays real, so latency numbers stay honest). Ignore `_test` entirely when `is_test = false`.

Scoring (runs after guards; does not depend on the LLM for structured form input):

- `missing_fields` = each of `required_fields` that is blank (`postcode` counts as blank when `postcode_area` is NULL; `urgency = unknown` counts as blank).
- **HOT**: `missing_fields` empty AND `urgency` in `hot_urgencies`.
- **WARM**: passed all guards, anything else.
- **COLD**: only rejected leads (always with a `reject_reason`).
- `score_reason` stores the rule that fired, e.g. `in_area+urgent+complete`, `missing:urgency`.

The LLM never decides the score. It extracts, flags spam/scope, and drafts.

## 4. LLM contract

Full JSON Schema and prompt: `prompts/lead-qualification.md` (version `lq-v1.0`).

```json
{
  "service": "string|null",
  "postcode": "string|null",
  "urgency": "emergency|this_week|flexible|unknown",
  "property_type": "string|null",
  "missing_fields": ["service|postcode|urgency|property_type|phone"],
  "is_spam": false,
  "in_scope": true,
  "language": "en",
  "reply_subject": "string",
  "reply_text": "string"
}
```

Handling rules (Workflow A, after the call - every outcome is logged to `llm_calls`):

| Outcome | `llm_calls.status` | Action |
|---|---|---|
| Valid JSON, passes schema | `ok` | continue |
| Not parseable | `invalid_json` | fallback template |
| Parseable but wrong shape/enum | `schema_violation` | fallback template |
| HTTP timeout (set 15 s) | `timeout` | fallback template |
| 429 | `rate_limited` | one retry after 2 s, then fallback template |
| Other 4xx/5xx | `error` | fallback template |
| `is_spam = true` | ok | `rejected / spam`, **discard** `reply_text`, do not send |
| `in_scope = false` | ok | `rejected / out_of_scope`, do not send |

Merge rule: LLM-extracted values only fill fields that are NULL after Normalize. Structured form input is never overwritten. Reply post-checks: contains `booking_url` exactly once (else append a deterministic line), no currency symbols or price words, under 120 words. Fail a check -> fallback template.

## 5. Event step vocabulary (`events.workflow` / `events.step`)

`intake`: `webhook_received`, `idempotent_skip`, `normalized`, `lead_inserted`, `guard_spam`, `guard_duplicate`, `guard_area`, `guard_hours`, `scored`, `llm_call`, `llm_validate`, `fallback_used`, `reply_built`, `reply_sent`, `crm_sync`, `owner_alert`, `lead_rejected`, `completed`

`booking`: `booking_received`, `booking_matched`, `booking_unmatched`, `booking_saved`, `crm_stage_updated`, `owner_alert`

`error`: `workflow_error` (Workflow C; `detail` carries node name and message; `lead_id` NULL if unknown)

`system`: `test_run`, `config_changed`

`status`: `ok` | `skip` (deliberately not done) | `warn` (degraded, e.g. fallback used) | `fail`.

## 6. Column write-map

Every column is written by exactly one place, so debugging means looking at one node.

| Columns | Written by | Step |
|---|---|---|
| `id, client_id, source, external_id, raw_payload, is_test, test_case_id, name, email, phone, country, service, postcode, urgency, property_type, t_received` | A | `lead_inserted` |
| `postcode_area, dedupe_key` | database (generated) | - |
| `reject_reason, duplicate_of, score='COLD'` | A | `guard_*` / `llm_validate` |
| `is_after_hours` | A | `guard_hours` |
| `missing_fields, score, score_reason` | A | `scored` |
| `status` | A, B, C | per section 1 |
| `reply_mode` | A | `reply_built` |
| `t_first_reply` | A | `reply_sent` |
| `t_booked` | B | `booking_saved` |
| `crm_provider, crm_contact_id, crm_deal_id, crm_status, crm_synced_at` | A (create) / B (stage) | `crm_sync` / `crm_stage_updated` |
| `do_not_contact, opted_out_at, followup_count, next_followup_at` | Phase 2 (columns exist, nothing writes them yet) | - |
| `llm_calls.*` | A | `llm_call` |
| `messages` inbound | A | `lead_inserted` |
| `messages` outbound, `sent_at, provider_message_id, delivery_status` | A | `reply_sent` |
| `messages.delivered_at` | optional provider webhook | - |
| `bookings.*` | B | `booking_saved` |
| `events.*` | A, B, C | every step |

## 7. Metric definitions (what the numbers mean - say this in the demo)

- `t_received`: time n8n captured in the first node after the webhook received the HTTP request. Not the browser's submit time (client clocks can't be trusted) and not the DB insert time.
- `t_first_reply`: time the email provider's API returned success for the send ("accepted"). **Not** inbox arrival.
- `response_ms` = `t_first_reply - t_received`. It measures pipeline latency. It does not include browser-to-webhook network time or provider-to-inbox delay.
- Report p50 and p95 from `v_sla_summary`, filtered by `is_test`, and label synthetic runs as synthetic.

## 8. Change protocol

1. Never edit an applied migration. Add `004_<what>.sql`, wrapped in `BEGIN/COMMIT`, ending with an `INSERT INTO schema_migrations`.
2. Additive only: new columns are nullable or have defaults. To rename, add the new column, backfill, switch workflows, drop the old one in a later migration.
3. Changing a `CHECK` list = `DROP CONSTRAINT` + `ADD CONSTRAINT` in a migration.
4. Same commit: update this file, `tests/db_smoke_test.sql`, and `tests/synthetic-leads.json` if behavior changes.
5. Before touching n8n: `psql -f tests/db_smoke_test.sql` must print `ALL DB SMOKE TESTS PASSED`.
6. Anything that doesn't deserve a column yet goes in `leads.meta` or `client_config.settings`; promote it to a column only once two workflows read it.
