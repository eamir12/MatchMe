-- Seed translations for age/height units used in Match Inspector
BEGIN;
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchInspectorAgeUnit', 'years'),
  ('es', 'matchInspectorAgeUnit', 'años'),
  ('he', 'matchInspectorAgeUnit', 'שנים'),
  ('en', 'matchInspectorHeightUnit', 'centimeters'),
  ('es', 'matchInspectorHeightUnit', 'centímetros'),
  ('he', 'matchInspectorHeightUnit', 'סנטימטרים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
COMMIT;
