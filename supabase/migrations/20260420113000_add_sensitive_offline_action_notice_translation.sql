BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'offlineSensitiveActionsRequireInternet', 'These features require an active internet connection.'),
  ('es', 'offlineSensitiveActionsRequireInternet', 'Estas funciones requieren una conexion activa a internet.'),
  ('he', 'offlineSensitiveActionsRequireInternet', 'התכונות האלה דורשות חיבור אינטרנט פעיל.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
