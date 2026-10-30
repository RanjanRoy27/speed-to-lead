# Import and configure the Speed-to-Lead workflows

These exports target n8n 2.35.7 and the schema in `database/001_initial_schema.sql` through `003_security.sql`. Credentials are deliberately unbound: after import, open each credential-using node and select your saved credential. Do not put passwords or API keys in workflow JSON.

## Public form vertical slice candidate

The repo now includes `form/index.html`, `form/config.js`, and `workflow-a-public-intake-v2.json`. This is a separate, inactive candidate for the first form-to-database-to-template-email demo. It does not replace the previously imported A workflow. Read [form/README.md](../form/README.md) and [specs/WF-A-public-intake-v2.md](specs/WF-A-public-intake-v2.md) before importing it.

Import the candidate as a new inactive workflow, select your tested Postgres and Gmail SMTP credentials on its nodes, then set Workflow C as its Error Workflow. Configure `form/config.js` with the candidate's production webhook URL. For a local form served on port 8000, leave Allowed Origins as `http://localhost:8000`; for a hosted form, change it to that exact HTTPS origin. Set `client_config.settings.demo_recipient_allowlist` to the controlled test inbox using the SQL in `form/README.md`. The workflow is demo-only and writes `is_test=true`.

The webhook returns `202` after it has stored or recognized the submission. It does not wait for email delivery. The form shows a received state, and the reply arrives separately. The candidate checks deterministic spam, duplicate person, service area, after-hours, score, and the demo recipient allowlist before sending. A send failure records the lead as failed, then throws to Workflow C for the Telegram alert.

## Before importing

1. Confirm `database/seed_demo.sql` has been run and `tests/db_smoke_test.sql` prints `ALL DB SMOKE TESTS PASSED`.
2. Replace `REPLACE_ME` in `client_config` for the demo client you will use. Configure a real Cal.com booking URL, valid sender/owner email, and (for alerts) a Telegram chat ID. The workflows use the seeded slug `abc-roofing` by default; change the SQL lookup to another active client slug when needed.
3. Your n8n Postgres credential must connect to the Supabase **direct** database endpoint, SSL enabled, as the table owner (or a role with explicit table/view/function privileges). A pooled transaction endpoint can fail with prepared statements. From Docker Desktop, `localhost` points at the container; use the Supabase hostname, not host localhost.

## Import

In n8n choose **Workflows → Import from File**, importing `workflow-c-intake-errors.json`, then `workflow-a-intake-template.json`, then `workflow-b-calcom-booking.json`. Save each and select the credential(s) described below. Activate A and B only after credentials and config are correct. C is invoked through each workflow's Error Workflow setting; choose C in A and B settings. Error Trigger workflows cannot be manually executed as a normal test; cause a controlled error in a scratch workflow to verify it.

## Credentials

### Supabase Postgres (required for all three)

In each Postgres node select your saved Postgres credential. It needs host, database, user, password, port 5432 and SSL enabled. If n8n's role is not the owner, grant access to `client_config`, `leads`, `messages`, `bookings`, `events`, `llm_calls`, and the three views. RLS is enabled with no end-user policies; use the database owner/server-side role for n8n, never expose this credential in a browser.

### Email (Workflow A)

The baseline A workflow ends after database intake and audit logging. It intentionally does not send a reply: fill `client_config.from_email` and configure a provider before enabling external sends. For SMTP, add an SMTP Send Email node after the approved reply-building stage and select an SMTP credential (host, port, TLS, username, password); use the business sender address. Persist provider acceptance, `messages` outbound row, `leads.t_first_reply/status/reply_mode`, and `events.reply_sent` only after a successful send. For production, a provider API with idempotency is preferable because a workflow retry after provider acceptance can otherwise duplicate mail.

### Telegram (Workflow C)

Create a Telegram bot with BotFather, obtain its token, and create a Telegram credential in n8n. Select it in the Telegram node. Put the destination chat ID in `client_config.owner_telegram_id` (the exported error workflow has a visible `REPLACE_WITH_TELEGRAM_CHAT_ID` placeholder). The event insert happens before alert delivery, so Telegram failure does not erase the error record.

### Gemini (not included as an active node yet)

Workflow A currently implements the safe deterministic intake/database slice. To enable LLM qualification, add an HTTP Request node after deterministic guards, call Gemini `generateContent` with JSON response MIME type/schema from `prompts/lead-qualification.md`, set 15 s timeout and only one retry on 429. Store *every* outcome in `llm_calls` (`provider='gemini'`, model, `prompt_version='lq-v1.0'`, status, raw/parsed response, latency/error). Validate the returned object in a Code node; never let the model set `score`. Merge extracted fields only where normalized form values are null. Invalid JSON/schema, timeout, rate limit after retry, and other provider errors must use configured fallback subject/body and log `fallback_used`. Valid spam/out-of-scope outputs reject without sending. Free-tier model credentials must only receive synthetic data.

## Webhooks and local Docker

Workflow A exposes `POST /webhook/speed-to-lead-intake`; B exposes `POST /webhook/calcom-booking`. Activate the workflows to get production URLs. Test URLs are available from the editor while listening for a test event. A Cal.com webhook requires an externally reachable URL; localhost is not reachable from Cal.com without a tunnel or public reverse proxy. Configure a signing secret and verify Cal.com signatures before processing live booking events; the included B export is a starter and currently documents where the provider event mapping must be confirmed from a captured webhook.

The intake expects a JSON body matching the internal fields in `docs/contracts.md` (at minimum `client_slug`, name and either email or phone; optional `submission_id`, service, postcode, urgency, property_type, message, honeypot, is_test, test_case_id). Use an HTML form or a caller that generates a UUID `submission_id`; repeat the same submission ID to confirm idempotency. It responds immediately with an accepted acknowledgement.

## Current scope and items needed from you

The repo does not provide the actual production form, client slug choice, mail provider, Cal.com webhook sample/signature setup, or HubSpot portal/pipeline/stage IDs. Those are deployment inputs. The A workflow export is the initial deterministic intake slice, not the completed phases 4–10 in the README. In particular it does not yet send replies, call Gemini, sync HubSpot, perform all scoring/after-hours rules, or send HOT/booking owner alerts. Do not represent it as meeting the 60-second reply target until those phases are implemented and tested.
