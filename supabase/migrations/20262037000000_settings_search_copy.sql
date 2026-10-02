INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'settingsSearch', 'Search settings'),
  ('en', 'settingsSearchHint', 'Find a setting'),
  ('en', 'settingsSearchNoResults', 'No matching settings'),
  ('es', 'settingsSearch', 'Buscar ajustes'),
  ('es', 'settingsSearchHint', 'Buscar un ajuste'),
  ('es', 'settingsSearchNoResults', 'No hay ajustes coincidentes'),
  ('he', 'settingsSearch', 'חיפוש בהגדרות'),
  ('he', 'settingsSearchHint', 'מצאו הגדרה'),
  ('he', 'settingsSearchNoResults', 'לא נמצאו הגדרות תואמות')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
