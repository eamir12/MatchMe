BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profilePersonalInterests', 'Personal Interests'),
  ('es', 'profilePersonalInterests', 'Intereses personales'),
  ('he', 'profilePersonalInterests', 'תחומי עניין אישיים'),

  ('en', 'profileBusinessInterests', 'Business & Networking'),
  ('es', 'profileBusinessInterests', 'Negocios y networking'),
  ('he', 'profileBusinessInterests', 'עסקים ונטוורקינג')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
