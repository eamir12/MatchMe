BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncProviderTitle', 'Choose calendar provider', 'en'),
  ('calendarSyncSourceTitle', 'Choose import source', 'en'),
  ('calendarSyncProviderGoogle', 'Google', 'en'),
  ('calendarSyncProviderOutlook', 'Outlook', 'en'),
  ('calendarSyncProviderApple', 'Apple', 'en'),
  ('calendarSyncPreferredBadge', 'Preferred', 'en'),
  ('calendarSyncSourceDevice', 'Device calendar', 'en'),
  ('calendarSyncSourceOnline', 'Online calendar', 'en'),
  ('calendarSyncSourceWebOnly', 'Web uses online calendar sign-in. Choose a provider and connect.', 'en'),
  ('calendarSyncConnectApple', 'Connect Apple Calendar', 'en'),
  ('calendarSyncNoCalendarsApple', 'No Apple calendars found on this device. Make sure iCloud Calendar is enabled in your device account settings.', 'en'),
  ('calendarSyncAppleWebNotSupported', 'Apple Calendar import on web is not available yet. Use iOS, macOS, or another device with Apple calendars enabled.', 'en'),
  ('eventsImportGoogle', 'Import Google', 'en'),
  ('eventsImportOutlook', 'Import Outlook', 'en'),
  ('eventsImportApple', 'Import Apple', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncProviderTitle', 'Elige proveedor de calendario', 'es'),
  ('calendarSyncSourceTitle', 'Elige fuente de importación', 'es'),
  ('calendarSyncProviderGoogle', 'Google', 'es'),
  ('calendarSyncProviderOutlook', 'Outlook', 'es'),
  ('calendarSyncProviderApple', 'Apple', 'es'),
  ('calendarSyncPreferredBadge', 'Preferido', 'es'),
  ('calendarSyncSourceDevice', 'Calendario del dispositivo', 'es'),
  ('calendarSyncSourceOnline', 'Calendario en línea', 'es'),
  ('calendarSyncSourceWebOnly', 'La web usa inicio de sesión de calendario en línea. Elige un proveedor y conéctate.', 'es'),
  ('calendarSyncConnectApple', 'Conectar calendario de Apple', 'es'),
  ('calendarSyncNoCalendarsApple', 'No se encontraron calendarios de Apple en este dispositivo. Asegúrate de que iCloud Calendar esté habilitado en la configuración de tu cuenta del dispositivo.', 'es'),
  ('calendarSyncAppleWebNotSupported', 'La importación de Apple Calendar en web todavía no está disponible. Usa iOS, macOS u otro dispositivo con calendarios de Apple habilitados.', 'es'),
  ('eventsImportGoogle', 'Importar Google', 'es'),
  ('eventsImportOutlook', 'Importar Outlook', 'es'),
  ('eventsImportApple', 'Importar Apple', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncProviderTitle', 'בחר ספק יומן', 'he'),
  ('calendarSyncSourceTitle', 'בחר מקור ייבוא', 'he'),
  ('calendarSyncProviderGoogle', 'Google', 'he'),
  ('calendarSyncProviderOutlook', 'Outlook', 'he'),
  ('calendarSyncProviderApple', 'Apple', 'he'),
  ('calendarSyncPreferredBadge', 'מומלץ', 'he'),
  ('calendarSyncSourceDevice', 'יומן המכשיר', 'he'),
  ('calendarSyncSourceOnline', 'יומן מקוון', 'he'),
  ('calendarSyncSourceWebOnly', 'באתר נעשה שימוש בהתחברות יומן מקוון. בחר ספק והתחבר.', 'he'),
  ('calendarSyncConnectApple', 'חיבור יומן Apple', 'he'),
  ('calendarSyncNoCalendarsApple', 'לא נמצאו יומני Apple במכשיר זה. ודא/י ש-iCloud Calendar מופעל בהגדרות החשבון במכשיר.', 'he'),
  ('calendarSyncAppleWebNotSupported', 'ייבוא Apple Calendar בווב עדיין לא זמין. השתמש/י ב-iOS, macOS או במכשיר אחר עם יומני Apple פעילים.', 'he'),
  ('eventsImportGoogle', 'ייבוא Google', 'he'),
  ('eventsImportOutlook', 'ייבוא Outlook', 'he'),
  ('eventsImportApple', 'ייבוא Apple', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
