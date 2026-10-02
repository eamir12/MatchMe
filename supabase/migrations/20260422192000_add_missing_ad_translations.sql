BEGIN;

-- Add missing translation keys for ad settings
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'generalCancel', 'Cancel'),
  ('es', 'generalCancel', 'Cancelar'),
  ('he', 'generalCancel', 'ביטול'),

  ('en', 'generalSave', 'Save'),
  ('es', 'generalSave', 'Guardar'),
  ('he', 'generalSave', 'שמור'),

  ('en', 'generalClose', 'Close'),
  ('es', 'generalClose', 'Cerrar'),
  ('he', 'generalClose', 'סגור')

ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
