# Public lead form setup

This is a static demo form. It posts JSON to the n8n production webhook and displays an acknowledgement after n8n has inserted (or recognized) the lead. The email is sent by the workflow afterward; the browser does not wait for delivery.

## Connect it to n8n

1. Import `n8n/workflow-a-public-intake-v2.json` into n8n as an inactive candidate. Keep the currently working Workflow A unchanged.
2. Select your tested Postgres credential on every Postgres node and your tested Gmail SMTP credential on the email node. Set Workflow C as this candidate's Error Workflow.
3. Check the Webhook node's production URL. It should end in `/webhook/speed-to-lead-public-v2`. Do not use a test URL for a hosted form.
4. Copy that complete URL into `form/config.js`, replacing `YOUR-N8N-HOST`. The server-side workflow fixes the client to `abc-roofing` so a browser cannot choose another tenant.
5. For local browser testing, serve this directory over HTTP (for example, `python -m http.server 8000` from `form/`). In the Webhook node, set Allowed Origins (CORS) to `http://localhost:8000`.
6. Open `http://localhost:8000`, submit a test lead using an inbox you control, and inspect n8n Executions plus Supabase. For a hosted form, replace the CORS origin with the exact HTTPS origin where the form is hosted.

For local testing, open PowerShell in the repo's `form` folder and run `python -m http.server 8000`; keep that terminal open while testing. This serves only the static form and does not need access to Supabase.

Before sending a test, allowlist the exact test inbox in the demo client configuration. In Supabase SQL Editor, replace the address and run:

```sql
UPDATE client_config
SET settings = jsonb_set(
  COALESCE(settings, '{}'::jsonb),
  '{demo_recipient_allowlist}',
  '["your-test-inbox@example.com"]'::jsonb,
  true
)
WHERE slug = 'abc-roofing';
```

The workflow rejects the request for automated email if the submitted address is not in this server-side list. Add only inboxes you control for the demo. This safeguard is in addition to the form honeypot, not a replacement for public traffic protection.

The form needs no database credential, SMTP credential, or other secret. Do not put credentials in `config.js`.

## Publish as a static site

Host `index.html` and `config.js` together on a static host such as GitHub Pages. Set Allowed Origins (CORS) to the form site's **origin** (scheme + hostname + optional port, no path). For example, a project page at `https://USERNAME.github.io/speed-to-lead/` has the origin `https://USERNAME.github.io`. The form must call the n8n **production** URL and the workflow must be active/published.

## What the user sees

The form shows “Request received” after the database insert succeeds. This means the request was accepted; it does not mean the email has arrived. The template email is sent later by Workflow A. If the request times out, retrying uses the same submission ID so the database uniqueness constraint prevents a second lead or reply.


## Confirm the end-to-end rows

After submitting the form, use Supabase SQL Editor:

```sql
-- Latest form leads for ABC Roofing, with the SLA result
SELECT l.id, l.name, l.email, l.service, l.postcode, l.postcode_area,
       l.status, l.score, l.reject_reason, l.reply_mode,
       l.t_received, l.t_first_reply, s.response_ms, s.within_60s
FROM leads l
LEFT JOIN v_lead_sla s ON s.lead_id = l.id
JOIN client_config c ON c.id = l.client_id
WHERE c.slug = 'abc-roofing'
ORDER BY l.t_received DESC
LIMIT 10;

-- Audit trail for the selected lead (replace the UUID from the first query)
SELECT workflow, step, status, error, detail, ts
FROM events
WHERE lead_id = 'PASTE-LEAD-UUID-HERE'
ORDER BY ts, id;

-- The inbound form message and any outbound template reply
SELECT direction, channel, author, subject, body, provider,
       delivery_status, sent_at, ts
FROM messages
WHERE lead_id = 'PASTE-LEAD-UUID-HERE'
ORDER BY ts;
```

For an allowlisted, eligible address, expect `received` -> `processing` -> `replied`, an inbound and outbound message, guard/score/reply/completed events, and a populated `response_ms`. For a rejected lead, inspect `reject_reason` and `lead_rejected`; no reply is expected. An address outside the demo allowlist is marked `suppressed` and receives no email.

## Check idempotency with the same request twice

The form creates a fresh submission ID for a new form attempt, so two ordinary submissions are two inquiries. To simulate a browser retry after a lost response, send one exact payload twice from PowerShell. Replace the URL and use the allowlisted inbox:

```powershell
$webhookUrl = 'https://YOUR-N8N-HOST/webhook/speed-to-lead-public-v2'
$payload = @{
  submission_id = 'demo-retry-001'
  name = 'Demo User'
  email = 'your-test-inbox@example.com'
  phone = '+61400000000'
  service = 'roof repair'
  postcode = '4101'
  urgency = 'this_week'
  property_type = 'house'
  message = 'Please inspect a damaged roof tile.'
  consent = $true
  honeypot = ''
} | ConvertTo-Json

Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json' -Body $payload
Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json' -Body $payload
```

Both responses should be accepted, with the second reporting `already_received`. There should be one lead and at most one outbound message for that submission ID.

## Demo safety

This candidate is configured to record form submissions as synthetic demo data and only send email to recipients in `client_config.settings.demo_recipient_allowlist`. Do not use it for actual customer intake until the workflow's demo flag is changed and public traffic protections are added. CORS only controls which browsers may read responses; it does not stop direct callers. Before sharing broadly, add a server-side CAPTCHA/rate-limit or equivalent edge protection and decide how to handle invalid/out-of-area submissions. The webhook's honeypot is only a basic spam signal.
