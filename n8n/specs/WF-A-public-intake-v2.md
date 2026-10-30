# Workflow A public intake v2 â€” demo slice

## Purpose

Receive the ABC Roofing demo form, durably record a lead, acknowledge receipt to the browser, apply the deterministic contract rules, send a template reply to eligible/allowlisted demo addresses, and persist the provider-accepted reply/SLA data.

This is a **demo candidate**. It is inactive by default, marks form submissions as synthetic (`is_test=true`), and only sends to email addresses listed in `client_config.settings.demo_recipient_allowlist`. The existing imported Workflow A is preserved.

## Node contract

| Node | Reads | Writes/behavior | Next |
|---|---|---|---|
| Public Lead Form Webhook | JSON POST | Receives `speed-to-lead-public-v2`; CORS origin is local dev by default | Normalize |
| Normalize and validate form | Form JSON | Validates name/email/service/postcode/urgency/consent; normalizes email and Australian phone; fixes `client_slug=abc-roofing`, `source=web_form`, `is_test=true`; creates or keeps `submission_id`; captures `t_received`; preserves allowlisted request fields in `raw_payload` | IF valid |
| Form data valid? | `valid` boolean | Routes invalid requests to 400 response | Insert or invalid response |
| Return validation message | validation error text | Responds 400 JSON; does not insert a lead | End |
| Insert lead and inbound audit | Normalized form fields | One parameterized SQL statement loads client config, inserts `leads`, `messages` inbound, `webhook_received` and `lead_inserted` events. Conflict writes `idempotent_skip`; duplicate request returns `inserted=false` | Acknowledge |
| Acknowledge stored request | Insert result | Responds HTTP 202 JSON `{accepted,status,lead_id,message}` after database insert/conflict resolution. The workflow continues after the response | Apply guards |
| Apply guards and score lead | `lead_id`, `inserted` | One parameterized SQL statement applies spam, 24-hour person duplicate, service area, demo recipient allowlist, local business hours, missing-field and score rules. Writes rule/score/rejection events. Rejected or idempotent requests return no item, so no email node runs. Duplicate message is appended to the original lead | Build reply only for accepted leads |
| Build template reply | Eligible lead + client config | Expands `{{name}}`, `{{service}}`, `{{booking_url}}`, `{{client_name}}`; appends after-hours note and a plain-text copy of the submitted fields/message so the submitter can review what was received | Record reply built |
| Record template reply built | Lead and rendered template | Sets `reply_mode='fallback'` at the contract's `reply_built` step and writes the `reply_built` event | Send template email |
| Send template email | Recipient, sender, subject, body | SMTP send using operator-selected credential. Error output is connected separately | Success/failure SQL |
| Record accepted email and SLA | Template fields after SMTP success | Sets status `replied` and `t_first_reply`; inserts outbound message (`provider=smtp`, `delivery_status=sent`) and `reply_sent` + `completed` events | End |
| Record failed email attempt | SMTP error branch | Sets status `failed` if no successful reply time; records `reply_sent` with `status=fail` and provider error | Stop And Error |
| Trigger central error workflow | Failure record | Throws an error after lead state is saved, so configured Workflow C receives the error and sends Telegram | C |

## Database alignment

No table or column is added. Writes follow `docs/contracts.md` sections 1, 3, 5 and 6. `reply_mode='none'` is written for rejection; eligible leads receive `fallback` at reply build. The outbound provider time is recorded only after SMTP accepts the message, so `v_lead_sla.response_ms` retains its documented meaning.

Demo-only recipient protection reads a JSON string array at `client_config.settings.demo_recipient_allowlist`. An empty or missing list suppresses sends and records `reject_reason='suppressed'`. The operator sets this list using the SQL snippet in `form/README.md`.

## Response and delivery semantics

The form receives a 202 response after the lead insert succeeds or the unique key identifies an existing submission. It says the request was received; it does not wait for SMTP. Email sending runs afterward in the same workflow execution. A visitor sees the email later in their mailbox. Invalid form input receives a 400 JSON response.

If a browser times out after the insert, its retry reuses the pending submission ID. The unique key prevents a second lead and reply. This does not provide a distributed transaction between SMTP and Postgres; an infrastructure crash after SMTP accepts and before the success SQL executes can require manual reconciliation.

## Import notes

- Target export version mirrors the repo's existing n8n 2.35.7 / Postgres node 2.6 conventions.
- Credentials and Error Workflow assignment are instance-specific; select them after import.
- CORS is set to `http://localhost:8000`. Replace with the exact form origin after hosting.
- Workflow is inactive in the export. Only activate after credential selection, client config, allowlist, and test submission.
