# Speed-to-Lead demo build plan

## Goal and scope

Build the smallest credible demo for one fictional business first: a lead arrives, is recorded once, receives a safe reply within 60 seconds, and can be followed through booking and an audit timeline. Postgres is the source of truth; n8n moves the state. Keep the current lead state machine, field ownership, event vocabulary, scoring rules, LLM contract, and metric definitions in `contracts.md` authoritative.

Use one seeded client for the first demo (recommended: `abc-roofing`, AU). Keep the other seeded clients for later configuration checks. The first demo is synthetic data only. Do not put secrets in exported workflow JSON or send real lead PII to a free LLM tier.

## What exists now

- Database migrations `001`–`003`, demo seed data, a smoke-test SQL file, 26 synthetic cases, and lead/LLM contracts exist.
- Workflow C (central errors), Workflow A (intake and database insert), and Workflow B (starter Cal.com booking handler) are exported under `n8n/`.
- The current A export is an intake/database slice. It does not yet implement the guards and scoring contract, send the first reply, call an LLM, sync HubSpot, or send owner alerts. B still needs a real captured Cal.com payload and signature verification before live use.
- `README.md`'s aspirational phase table and `n8n/README-setup.md`'s description are out of sync. Treat this plan as the execution order; reconcile those docs and the actual exports in the first work package.

## Demo-first sequence

Each phase ends with a reviewable export, setup notes, and acceptance evidence. A workflow is not ready to import just because its JSON parses: node credentials stay unbound, node parameters are checked against the target n8n version, and every SQL write is reconciled with `contracts.md`.

| Phase | Build and owner | Deliverables | Exit condition |
|---|---|---|---|
| 0. Verify live state | You check Supabase/n8n; agent checks repo exports | Short state checklist; identify which imported workflows can be preserved | Existing credentials, database, and workflow versions are known; no deployed workflow is overwritten blindly |
| 1. Intake + error path | Agent: patch existing A/C exports; you: confirm credentials | Import-ready workflow revision and concise node-by-node setup guide | Same submission ID creates one lead; inbound message/events are written; C records a controlled workflow error and Telegram alerts |
| 2. Deterministic rules | Agent: extend A following the existing contract | Spam, duplicate-person, service-area, after-hours, missing-field, HOT/WARM/COLD handling | Synthetic rule cases match `contracts.md`; rejected leads receive no reply; after-hours leads remain eligible |
| 3. Template email + SLA (Demo v0) | Agent: reply branch and failure state; you: configure/test sender | Outbound email, outbound message, reply event, setup/runbook steps | Test email arrives; accepted send is logged with `t_first_reply`; failed send sets lead failed and is alerted; `v_lead_sla` returns a meaningful result under 60 seconds |
| 4. Demo rehearsal | Agent: final review and known-limits note; you: repeat the demo | Stable workflow exports, demo script, queries, reset/isolation instructions | Happy path and failure path are repeatable and accurately described |
| 5. AI qualification (after Demo v0) | Agent: LLM request, parser, and fallback path; you: provider key/model choice | Prompt-versioned request, strict validation, `llm_calls` audit, deterministic fallback | Valid, malformed, timeout, rate-limit, spam, and out-of-scope cases follow `contracts.md`; no model-controlled score; synthetic-only prompt tests |
| 6. Booking (after Demo v0) | Agent: Workflow B mapping/upsert; you: Cal.com test event | Import-ready B and a captured sanitized payload fixture | Create/reschedule/cancel events are idempotent, correctly matched, and update booking/lead state; unmatched booking is audited |
| 7. Later pilot work | Only if requested after demo acceptance | Hosting, CRM, owner lead alerts, production email delivery/reconciliation | Each feature gets its own scope and acceptance test; it does not block Demo v0 |

### Shortest useful demo

The optimal first demo is intake + deterministic safeguards/scoring + a **template reply** + failure alert + SLA evidence. It proves intake, persistence, safe routing, response timing, and a failure path without making a model call or booking provider a reliability dependency. Run the deterministic guards before sending mail so spam and out-of-area leads cannot trigger an external side effect. Add the LLM after this path works; retain the template fallback.

## Comparing the pasted execution plan

Keep these recommendations from it:

- Defer HubSpot, always-on hosting, live Facebook/WhatsApp, follow-ups, and a multi-tenant UI until after the demo. Postgres is the demo system of record. Since the schema does not automatically mark unsynced leads `crm_status='pending'`, describe CRM as “not integrated yet” and leave its status alone unless the workflow explicitly writes it.
- Use a real test email, the existing synthetic cases, the database timeline/SLA views, and one controlled failure as evidence. Keep the response-time caveat from `contracts.md` in the demo narration.
- Give agents narrow workflow assignments, preserve the existing schema, and require them to report assumptions, configuration steps, and acceptance evidence.

Change these parts before following it:

- **Do not build the full Python workflow generator first.** The repo already has A/B/C exports, and the first goal is one verified A flow. A generator, schema parser, SQL ownership linter, and HTTP-to-database synthetic runner are a separate engineering project. Start with a workflow spec and a small structural/SQL review. Add automation only after repeated edits show it will save time.
- **Do not map credential IDs in a committed file.** IDs belong to an n8n instance and do not make an export portable. Keep secrets and IDs out of Git; import the export and select the saved Postgres/SMTP/Telegram credentials in n8n. Assign Workflow C manually in each workflow's Error Workflow setting after import.
- **Do not enforce “only one node/workflow writes each column” literally.** The contract permits different workflows to own `status` at different transitions, and event rows are intentionally written by multiple workflows. Validate writes against the specific writer/step in `contracts.md` section 6.
- **Do not replace an already-running A/C workflow on the strength of a generated export.** Keep the current version, import a named candidate/inactive copy, inspect its credentials/settings, then switch only after the candidate passes its acceptance checks. Keep a rollback path.
- **Do not deliberately break a shared SMTP credential to test failure handling.** Use an isolated test credential or a test-only failure path that is gated on `is_test`; remove any failure injection before the demo release. Verify that Workflow A records `failed` itself, while Workflow C alerts on the workflow error.
- **Do not install a tunnel unless the chosen test method needs one.** A local synthetic POST can test a local n8n webhook without a hosted form. For a browser form or Cal.com callback, the webhook needs a reachable public URL, correct `WEBHOOK_URL` configuration, and CORS settings. Set the environment variable in the process/container that starts n8n; changing it in a separate shell after n8n is running will not update the production URL.
- **Do not use a placeholder booking URL as a required Demo v0 configuration.** Booking is deferred; keep that client field clearly marked as unconfigured until a real Cal.com event is in scope.

## Hands-on run for the first demo

Work in checkpoints and do not proceed past a failed checkpoint. The estimate is a target; account setup and debugging can take longer.

### Checkpoint A — confirm the starting point

1. In this repository, note the current Git changes and do not discard them. Confirm that `database/001`–`003`, the seed, contracts, and current A/B/C exports are present.
2. In Supabase, confirm the tables and views exist. Run the existing DB smoke test only if you can safely connect to the intended demo database; do not reapply `001` to an already initialized database.
3. In n8n, confirm the imported A and C workflows, the Postgres and Telegram credentials, and the Error Workflow assignment on A. Record the current workflow names/active state so you can restore them.
4. Use only the `abc-roofing` demo client for the first path. Do not share credential values; the operator enters them into the service UI.

**Stop if:** the database connection, imported workflow identity, or active state is uncertain. Resolve that before importing a replacement.

### Checkpoint B — prepare the sender and client data

1. Choose a test inbox you control. Configure SMTP in n8n with the email provider's supported settings and send a one-off test message from a scratch workflow. If using Gmail, use an App Password only if the account offers it; use the same authorized sender address in `client_config.from_email`.
2. Update only the demo client's non-secret values in Supabase: sender name/address, owner email, owner Telegram chat ID if C needs it, fallback subject/body, and service-area/business-hours data if they differ from the fictional seed. Do not put passwords or API keys in SQL or the repo.
3. Leave Cal.com booking URL and HubSpot settings out of the critical path. Do not tell the demo audience that CRM sync is active.

**Stop if:** the standalone email send does not arrive or the sender identity is rejected. Fix sender setup before debugging Workflow A.

### Checkpoint C — update and import Workflow A safely

1. Assign an agent one task: extend the existing A export (not a rewrite) for contract-compliant idempotency, deterministic guards/scoring, and a template email reply. Give it `docs/contracts.md`, `database/001_initial_schema.sql`, the current A/C exports, and the relevant synthetic cases. Forbid schema changes and credential IDs unless it identifies a real contract gap and stops for review.
2. Require the agent to deliver: updated workflow JSON under `n8n/`, a workflow spec, the exact import/config instructions, and a list of nodes/columns/events changed. Have it explain how duplicate IDs log `idempotent_skip`, how SMTP failure marks the lead failed, and how successful sending writes `messages`, `t_first_reply`, status, and the reply event.
3. Review the export for SQL parameterization, placeholder client slug, immediate/early webhook acknowledgement, failure handling, and credential placeholders. Compare every write to `contracts.md` section 6.
4. Import as an inactive candidate or preserve the previous workflow for rollback. Select Postgres/SMTP credentials in the nodes, set C as its Error Workflow, save, and check the webhook's production URL before activation.

**Stop if:** the candidate invents a column/status/event, embeds a secret, uses string-built SQL, or does not explain how the external email send and DB update are coordinated.

### Checkpoint D — prove the flow with synthetic cases

Run in this order, using a clean test dataset or unique submission IDs so prior runs do not change the expected result:

1. **Idempotency** (T010): send the same submission twice. Expect one logical lead, one inbound message for the accepted lead, an `idempotent_skip` audit for the repeated attempt, and no second reply.
2. **Deterministic rules** (T003–T007, T011, T012, T015, T020–T023): check score/reason, missing fields, rejection reason, duplicate link, service-area behavior, and after-hours flag against the fixtures. Only eligible cases proceed to email.
3. **Happy path** (T001): submit to the test inbox. Confirm one accepted email, one outbound message, a `reply_sent` event, `status='replied'`, and a non-null `t_first_reply`.
4. **Failure path** (T019): cause a controlled failure in an isolated test setup. Confirm A leaves the lead `failed` with no successful `t_first_reply`, and C stores/alerts the workflow error. Do not corrupt the only shared credential to simulate this.
5. Query `v_lead_timeline` and `v_lead_sla` for the same lead. State the metric accurately: webhook arrival to email provider acceptance, not inbox delivery.

**Demo v0 is complete when:** the happy path and controlled failure are repeatable; every expected row/event is present; the email reaches the test inbox; and the SLA result is honest and under 60 seconds for the demonstrated test.

### What you do after Demo v0

Stop adding features and rehearse/record the demo. Then add one module at a time: LLM with fallback and `llm_calls` audit; then Cal.com from a real captured payload; then any requested hosting/CRM work. Run the complete 26-case suite only when the behaviors represented by those cases are implemented. T001/T002 currently expect `reply_mode='ai'`; while validating the template-only milestone, use a phase-specific acceptance check that expects the agreed template mode. Keep the full fixtures' final expectations intact for the later LLM milestone unless a contract-first change is approved.

## Agent work protocol

Delegate bounded deliverables, not an open-ended request to "build the workflow." Give each coding agent the following instruction:

> Read `README.md`, `docs/contracts.md`, `prompts/lead-qualification.md`, the existing SQL migrations, and the current workflow exports before editing. Preserve the schema and event/column contracts. For behavior or schema changes, update the contract first, then add a numbered migration if required, then the workflow, then synthetic fixtures/DB checks in the same change. Never edit an applied migration. Export one n8n workflow JSON per workflow under `n8n/`; leave credentials unbound and secrets out of JSON. Use Postgres query parameters, not SQL string interpolation. Include the target n8n version, required credentials, exact import/config steps, expected input/output, failure behavior, and acceptance evidence. Do not claim a provider event format is verified unless it came from a captured sanitized payload.

Use one agent per independent workflow or contract package. Integration stays serial at the contract boundary: review and accept a schema/contract change before assigning downstream workflow work. Every agent should report changed files, node-by-node behavior, external configuration still needed, and any assumptions. Import and activate only after a human reviews the export and assigns credentials/config in n8n.

### Suggested work packages

1. **Integration lead (me):** maintain this plan and contracts, review SQL/schema ownership, resolve cross-workflow naming and state transitions, and check exports for consistency.
2. **Database package agent:** only when a contract gap is established; propose additive migration, update contract and smoke assertions, document apply/rollback implications. Avoid migrations for per-client data or settings.
3. **Workflow A agent:** intake, guards, scoring, reply, optional LLM/fallback. Keep all writes and event names aligned with the column write-map.
4. **Workflow B agent:** Cal.com mapping, webhook authentication, matching, upsert, cancellation/reschedule semantics.
5. **Workflow C/CRM package agent:** central error event and notifications; later HubSpot create/update and stage mapping. CRM retries must be idempotent.

Agents should not edit the same workflow or contract files concurrently. Assign phases in dependency order and merge/review one package before asking another agent to build on it.

## Import and configuration sequence

Keep detailed click-by-click instructions in `n8n/README-setup.md`; update it alongside workflow exports. The operator sequence is:

1. Create a dedicated demo database/project and apply `001`, `002`, `003`, then `seed_demo.sql`; run `tests/db_smoke_test.sql`.
2. Choose a demo client and update its booking URL, sender details, owner contact, business hours, service areas, and fallback text through SQL data updates. Never edit an applied migration for these values.
3. In n8n, create credentials for Postgres (direct/session endpoint, SSL), email, Telegram, and later LLM/Cal.com/HubSpot as used. Keep credentials in n8n's credential store.
4. Import C, then A, then B; select credentials on each node and set C as the error workflow where appropriate. Update client slug/config in each export or centralize that choice consistently.
5. Use test webhook URLs and synthetic fixtures first. Confirm DB rows, events, emails, booking updates, and failure behavior before activating production URLs.
6. Configure provider webhooks against reachable n8n URLs; verify signatures; then activate only the workflows in the completed milestone.
7. Rehearse the demo and describe `response_ms` as webhook-arrival to provider-accepted time, not inbox delivery time.

## Decisions needed from you

These are the only choices needed to begin. Recommended defaults are included so we can move quickly.

| Choice | Recommended first-demo default | Needed from you |
|---|---|---|
| Demo business | `abc-roofing` fictional AU client | Confirm, or choose `northern-solar` / `maple-maid` |
| Database host | Existing Supabase if already provisioned; otherwise choose Supabase or Neon | Provider and whether a project/database already exists (never send credentials here) |
| n8n host | Your existing n8n instance; local/test URL for initial imports | Where it runs and whether it can receive public webhooks |
| First reply channel | Email, using a dedicated demo sender | Which sender/provider you can configure (SMTP or email API) |
| First demo boundary | Intake + template reply + audit/SLA; booking as milestone two | Confirm this order or state a required booking/CRM feature for the first showing |
| LLM | Defer until template path works; Gemini or another provider later, synthetic inputs only | Preferred provider/model if you want it in the first demo |
| Cal.com and CRM | Defer HubSpot until the booking path works | Whether you already have Cal.com/HubSpot accounts and want them in demo milestone one or two |
| Audience and date | Internal demo unless stated otherwise | Who will see it and any target date; this sets how much deployment hardening is needed |

Do not paste passwords, API keys, database URLs, or webhook signing secrets into chat or repository files. Use them directly in the provider dashboard and n8n credential UI.

## Operator-side checklist

You provide the accounts and environment-specific values; agents provide importable workflow/schema artifacts and guides.

- Create or identify the hosted Postgres project and n8n instance; confirm n8n can reach Postgres and public webhook providers can reach n8n.
- Select one demo client and supply non-secret business choices: service area, business hours, approved fallback copy, booking link, sender display name, owner alert destination.
- Create provider accounts/keys for only the agreed phase. Add credentials through n8n UI, then select them on imported nodes.
- Create test lead submissions and retain the resulting execution IDs so failures can be diagnosed.
- Capture a real Cal.com test webhook and share a sanitized fixture with the build process; keep signatures/secrets private.
- Apply migrations and import/activate workflows using the supplied guides. Confirm each exit condition before enabling the next external side effect.
- Approve the demo claims: synthetic vs real records, pipeline latency definition, and any known limits.

## Scope held for later

Follow-up cadence, opt-out/inbound SMS or WhatsApp, multi-client self-service, custom dashboards, concurrency-safe person dedupe, and production-grade email delivery/reconciliation remain later work unless the demo audience requires them. The current schema has hooks for some of these; the existence of columns does not mean the behavior is implemented.
