-- =====================================================================
-- seed_demo.sql  -  three FICTIONAL demo clients (one per target country)
-- Replace every REPLACE_ME value before a live demo (booking URL, emails, Telegram id).
-- Safe to re-run: upserts on slug.
-- =====================================================================
BEGIN;

INSERT INTO client_config
  (slug, client_name, industry, country, timezone, services, service_areas,
   business_hours, tone, reply_signature, after_hours_note, booking_url,
   from_name, from_email, owner_email, owner_telegram_id,
   fallback_subject, fallback_body, crm_config)
VALUES
-- ---------------- AU: roofing ----------------
('abc-roofing', 'ABC Roofing', 'roofing', 'AU', 'Australia/Brisbane',
 ARRAY['roof repair','roof replacement','roof inspection','gutter repair','leak detection'],
 ARRAY['4101','4102','4103','4104','4105'],
 '{"mon":[["07:30","17:00"]],"tue":[["07:30","17:00"]],"wed":[["07:30","17:00"]],"thu":[["07:30","17:00"]],"fri":[["07:30","17:00"]],"sat":[["08:00","12:00"]],"sun":[]}',
 'professional, friendly, plain Australian English',
 'The ABC Roofing team',
 'Our office is closed right now, but your enquiry is logged and we will be in touch first thing when we open.',
 'https://cal.com/REPLACE_ME/abc-roofing-inspection',
 'ABC Roofing', 'REPLACE_ME@yourdomain.com', 'REPLACE_ME@yourdomain.com', NULL,
 'Thanks for contacting ABC Roofing, {{name}}',
 E'Hi {{name}},\n\nThanks for getting in touch about {{service}}. We have your details and can get an inspection booked quickly.\n\nPick a time that suits you here: {{booking_url}}\n\n{{client_name}} team',
 '{"provider":"hubspot","pipeline_id":null,"stages":{"new":null,"booked":null}}'),

-- ---------------- GB: solar ----------------
('northern-solar', 'Northern Solar Ltd', 'solar', 'GB', 'Europe/London',
 ARRAY['solar panel installation','battery storage','solar survey','panel maintenance'],
 ARRAY['M1','M2','M3','M4','M14','M15'],
 '{"mon":[["08:30","17:30"]],"tue":[["08:30","17:30"]],"wed":[["08:30","17:30"]],"thu":[["08:30","17:30"]],"fri":[["08:30","17:00"]],"sat":[],"sun":[]}',
 'professional, warm, plain British English',
 'The Northern Solar team',
 'Our office is closed at the moment, but your enquiry is logged and we will reply when we open.',
 'https://cal.com/REPLACE_ME/northern-solar-survey',
 'Northern Solar', 'REPLACE_ME@yourdomain.com', 'REPLACE_ME@yourdomain.com', NULL,
 'Thanks for contacting Northern Solar, {{name}}',
 E'Hi {{name}},\n\nThanks for your enquiry about {{service}}. We would be happy to arrange a free survey.\n\nChoose a time that suits you here: {{booking_url}}\n\n{{client_name}} team',
 '{"provider":"hubspot","pipeline_id":null,"stages":{"new":null,"booked":null}}'),

-- ---------------- CA: cleaning ----------------
('maple-maid', 'Maple Maid Cleaning', 'cleaning', 'CA', 'America/Toronto',
 ARRAY['residential cleaning','deep clean','move-out clean','office cleaning'],
 ARRAY['M5V','M5H','M5J','M4Y','M5B'],
 '{"mon":[["08:00","18:00"]],"tue":[["08:00","18:00"]],"wed":[["08:00","18:00"]],"thu":[["08:00","18:00"]],"fri":[["08:00","18:00"]],"sat":[["09:00","15:00"]],"sun":[]}',
 'friendly, upbeat, plain Canadian English',
 'The Maple Maid team',
 'Our office is closed right now, but your request is logged and we will get back to you when we open.',
 'https://cal.com/REPLACE_ME/maple-maid-quote',
 'Maple Maid Cleaning', 'REPLACE_ME@yourdomain.com', 'REPLACE_ME@yourdomain.com', NULL,
 'Thanks for contacting Maple Maid, {{name}}',
 E'Hi {{name}},\n\nThanks for reaching out about {{service}}. We can get you a quote quickly.\n\nPick a time to chat here: {{booking_url}}\n\n{{client_name}} team',
 '{"provider":"hubspot","pipeline_id":null,"stages":{"new":null,"booked":null}}')
ON CONFLICT (slug) DO UPDATE SET
  client_name = EXCLUDED.client_name, services = EXCLUDED.services,
  service_areas = EXCLUDED.service_areas, business_hours = EXCLUDED.business_hours,
  tone = EXCLUDED.tone, reply_signature = EXCLUDED.reply_signature,
  after_hours_note = EXCLUDED.after_hours_note, booking_url = EXCLUDED.booking_url,
  fallback_subject = EXCLUDED.fallback_subject, fallback_body = EXCLUDED.fallback_body;

COMMIT;
