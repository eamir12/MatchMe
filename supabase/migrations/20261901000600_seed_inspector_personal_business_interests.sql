-- Seed translations for personal/business interests split in Match Inspector
BEGIN;
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchInspectorPersonalInterests', 'Personal interests'),
  ('es', 'matchInspectorPersonalInterests', 'Intereses personales'),
  ('he', 'matchInspectorPersonalInterests', 'תחומי עניין אישיים'),
  ('en', 'matchInspectorBusinessInterests', 'Business interests'),
  ('es', 'matchInspectorBusinessInterests', 'Intereses de negocio'),
  ('he', 'matchInspectorBusinessInterests', 'תחומי עניין עסקיים'),
  ('en', 'personalInterests', 'Personal interests'),
  ('es', 'personalInterests', 'Intereses personales'),
  ('he', 'personalInterests', 'תחומי עניין אישיים'),
  ('en', 'businessInterests', 'Business interests'),
  ('es', 'businessInterests', 'Intereses de negocio'),
  ('he', 'businessInterests', 'תחומי עניין עסקיים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
COMMIT;
