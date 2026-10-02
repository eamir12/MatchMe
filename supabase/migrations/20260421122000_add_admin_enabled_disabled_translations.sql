BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'generalEnabled', 'Enabled'),
  ('es', 'generalEnabled', 'Habilitado'),
  ('he', 'generalEnabled', 'מופעל'),
  ('en', 'generalDisabled', 'Disabled'),
  ('es', 'generalDisabled', 'Deshabilitado'),
  ('he', 'generalDisabled', 'מושבת')
ON CONFLICT (locale, key) DO UPDATE
SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
