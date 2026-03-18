BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncApplePublicUrlLabel', 'Apple public calendar URL', 'en'),
  ('calendarSyncApplePublicUrlHint', 'webcal://p01-calendarws.icloud.com/...', 'en'),
  ('calendarSyncApplePublicUrlHelp', 'Paste your public Apple calendar link to import events in read-only mode.', 'en'),
  ('calendarSyncApplePublicUrlRequired', 'Please paste your Apple public calendar URL.', 'en'),
  ('calendarSyncApplePublicUrlInvalid', 'Invalid Apple public calendar URL. Use a webcal:// or https:// link.', 'en'),
  ('calendarSyncApplePublicFetchFailed', 'Failed to fetch events from the Apple public calendar URL.', 'en'),
  ('calendarSyncApplePublicNoCalendars', 'No events were found for this Apple public calendar URL.', 'en'),
  ('calendarSyncApplePublicNoCalendars_male', 'No events were found for this Apple public calendar URL.', 'en'),
  ('calendarSyncApplePublicNoCalendars_female', 'No events were found for this Apple public calendar URL.', 'en'),
  ('calendarSyncApplePublicNoCalendars_non_binary', 'No events were found for this Apple public calendar URL.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncApplePublicUrlLabel', 'URL del calendario público de Apple', 'es'),
  ('calendarSyncApplePublicUrlHint', 'webcal://p01-calendarws.icloud.com/...', 'es'),
  ('calendarSyncApplePublicUrlHelp', 'Pega el enlace público de tu calendario de Apple para importar eventos en modo de solo lectura.', 'es'),
  ('calendarSyncApplePublicUrlRequired', 'Pega la URL pública de tu calendario de Apple.', 'es'),
  ('calendarSyncApplePublicUrlInvalid', 'URL de calendario público de Apple no válida. Usa un enlace webcal:// o https://.', 'es'),
  ('calendarSyncApplePublicFetchFailed', 'No se pudieron obtener eventos desde la URL del calendario público de Apple.', 'es'),
  ('calendarSyncApplePublicNoCalendars', 'No se encontraron eventos para esta URL de calendario público de Apple.', 'es'),
  ('calendarSyncApplePublicNoCalendars_male', 'No se encontraron eventos para esta URL de calendario público de Apple.', 'es'),
  ('calendarSyncApplePublicNoCalendars_female', 'No se encontraron eventos para esta URL de calendario público de Apple.', 'es'),
  ('calendarSyncApplePublicNoCalendars_non_binary', 'No se encontraron eventos para esta URL de calendario público de Apple.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncApplePublicUrlLabel', 'קישור יומן ציבורי של Apple', 'he'),
  ('calendarSyncApplePublicUrlHint', 'webcal://p01-calendarws.icloud.com/...', 'he'),
  ('calendarSyncApplePublicUrlHelp', 'הדבק/י קישור יומן ציבורי של Apple כדי לייבא אירועים במצב קריאה בלבד.', 'he'),
  ('calendarSyncApplePublicUrlRequired', 'יש להדביק קישור יומן ציבורי של Apple.', 'he'),
  ('calendarSyncApplePublicUrlInvalid', 'קישור יומן ציבורי של Apple לא תקין. יש להשתמש בקישור webcal:// או https://.', 'he'),
  ('calendarSyncApplePublicFetchFailed', 'נכשלה משיכת אירועים מקישור היומן הציבורי של Apple.', 'he'),
  ('calendarSyncApplePublicNoCalendars', 'לא נמצאו אירועים עבור קישור יומן ציבורי זה של Apple.', 'he'),
  ('calendarSyncApplePublicNoCalendars_male', 'לא נמצאו אירועים עבור קישור יומן ציבורי זה של Apple.', 'he'),
  ('calendarSyncApplePublicNoCalendars_female', 'לא נמצאו אירועים עבור קישור יומן ציבורי זה של Apple.', 'he'),
  ('calendarSyncApplePublicNoCalendars_non_binary', 'לא נמצאו אירועים עבור קישור יומן ציבורי זה של Apple.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
