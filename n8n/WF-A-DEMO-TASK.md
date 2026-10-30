# Agent task: Workflow A Demo v0

## Current operator status

As of 2026-10-28, the operator reports that the existing Postgres, Telegram, and SMTP credentials have been tested, and the existing A/B/C workflows are imported and working in n8n. Treat those running workflows as the baseline; do not delete, deactivate, overwrite, or assume the repository export exactly matches the imported version.

## Objective

Prepare a separate, reviewable Workflow A candidate that supports the first demo:

`web form -> idempotent lead intake -> deterministic guards and score -> template email -> message/event/SLA records`

Reuse the existing database schema. Workflow C continues to handle unexpected workflow errors and Telegram notifications. This milestone does not include LLM calls, Cal.com processing, HubSpot, follow-ups, or new database migrations.

## Read before editing

- `docs/contracts.md` (especially sections 1–3, 5–7)
- `database/001_initial_schema.sql`, `database/002_indexes_and_views.sql`, `database/003_security.sql`
- `database/seed_demo.sql`
- `n8n/workflow-a-intake-template.json` and `n8n/workflow-c-intake-errors.json`
- `n8n/README-setup.md`
- relevant cases in `tests/synthetic-leads.json`

Do not assume the repo export is byte-for-byte the live n8n workflow. Do not change the current A export in place. Produce a distinctly named candidate export, for example `n8n/workflow-a-demo-v2-candidate.json`.

## Required behavior

1. Normalize the request according to the lead object contract. Require email or a valid phone. Use the submitted `submission_id` as `external_id`; preserve the complete original request in `raw_payload`. Apply `_test.clock_local` only for `is_test=true`.
2. Capture `t_received` at the first node after webhook receipt. Insert a lead with a parameterized Postgres query. On `(client_id, source, external_id)` conflict, create no second lead and no second reply; write an `idempotent_skip` event and return an accepted acknowledgement.
3. Write the initial inbound message and `lead_inserted` event for a newly created lead.
4. Run guards in contract order: deterministic spam; 24-hour duplicate person; service area; after-hours flag. Record the corresponding event for each check. A duplicate is rejected and linked with `duplicate_of`; append its new inbound content to the original lead as required by the contract.
5. Apply the contract's `missing_fields`, HOT/WARM/COLD score, and score reason. Do not ask an LLM to score leads. After-hours does not reject a lead.
6. Rejected leads receive no email, have `status='rejected'`, `score='COLD'`, and a contract-approved `reject_reason`.
7. Eligible leads receive a template email from `client_config.fallback_subject` and `fallback_body`, with supported template substitutions. Append `after_hours_note` when required. Do not invent prices, guarantees, or staff names. Set `reply_mode='fallback'` for this milestone.
8. Only after the provider accepts the send, write the outbound `messages` row, set `t_first_reply`, set `status='replied'`, and record `reply_sent` as successful. Keep the SLA definition from `contracts.md` section 7.
9. If the email send fails, ensure Workflow A records the lead as `failed`, leaves `t_first_reply` null, and writes a failed reply event. Route this failure into Workflow C or otherwise ensure the configured error workflow alerts. Do not rely on C alone to change the lead state.
10. Return an HTTP acknowledgement promptly after intake is durably accepted; continue the reply processing without holding the form open for the email send. Document the exact n8n response behavior and any execution-order assumption.

## Contract and safety rules

- No migration or schema/contract edits in this task. If a required behavior cannot be implemented with current contracts, stop and report the exact conflict before coding.
- Use Postgres query parameters. Never interpolate user values into SQL text.
- Preserve the field write-map and event vocabulary in `docs/contracts.md`. `status` has multiple legitimate writers at different transitions; check each transition against the write-map rather than applying a global one-writer rule.
- Never commit credentials, API keys, database URLs, n8n credential IDs, or webhook secrets. The export should use credential placeholders/names that the operator can select after import.
- Do not include a committed credential-ID map or workflow-ID map. The operator assigns credentials and Error Workflow C in the target n8n instance.
- Do not add a test-only failure bypass to an active production path. Describe a safe isolated way to exercise send failure.
- Keep the current A/B/C workflow files intact. Do not create or edit a general workflow generator in this task.

## Deliverables

1. `n8n/workflow-a-demo-v2-candidate.json` (or similarly distinct candidate name).
2. `n8n/specs/WF-A-demo-v2.md`, listing every node, input/output, SQL write, event, branch, and failure behavior.
3. `n8n/README-setup.md` updates with import-as-inactive, credential selection, Error Workflow assignment, activation, rollback, and configuration steps for this candidate.
4. A short report listing files changed, assumptions, known limits, exact cases/checks covered, and anything the operator must still do.

## Acceptance evidence to provide

Give a node-by-node trace for these cases, mapped to the existing synthetic fixtures:

- T010: same submission sent twice; one lead and one reply maximum; duplicate attempt gets `idempotent_skip`.
- T003–T007: missing fields, invalid/out-of-area postcode, spam; expected score/status and no email for rejected cases.
- T011: duplicate person links to original and does not receive another reply.
- T012: after-hours remains eligible and gets the configured note.
- T001: eligible lead receives one template reply; outbound message and SLA timestamp are written.
- T019: send failure leaves `failed`, `t_first_reply` null, and an error alert is triggered.

The current fixtures describe final AI behavior for some T001/T002 expectations. Do not silently alter those fixtures or claim the full suite passes for this template-only milestone. Call out phase-specific expected differences explicitly.

## Operator import checklist

The operator will:

1. Keep current working A/B/C workflows unchanged while importing the candidate as a new inactive workflow.
2. Select the existing tested Postgres and SMTP credentials on candidate nodes.
3. Set Workflow C in the candidate's Error Workflow setting.
4. Review the configured client slug and confirm the `abc-roofing` seed values needed for email are set.
5. Save and test with synthetic data before activating. Preserve a rollback path to the previous A workflow.

Do not activate the candidate or claim it is verified in the hosted n8n instance. That requires operator import and acceptance checks.
