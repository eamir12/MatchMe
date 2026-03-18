BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportDeviceCalendar', 'Import from Device Calendar', 'en'),
  ('calendarSyncConnectDevice', 'Connect Device Calendar', 'en'),
  ('calendarSyncNoCalendarsDevice', 'No device calendars were found on this device.', 'en'),
  ('calendarSyncDeviceWebNotSupported', 'Import from Device Calendar is not available on web. Use Android, iOS, Windows, or macOS.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportDeviceCalendar', 'Importar desde el calendario del dispositivo', 'es'),
  ('calendarSyncConnectDevice', 'Conectar calendario del dispositivo', 'es'),
  ('calendarSyncNoCalendarsDevice', 'No se encontraron calendarios del dispositivo en este dispositivo.', 'es'),
  ('calendarSyncDeviceWebNotSupported', 'Importar desde el calendario del dispositivo no está disponible en la web. Usa Android, iOS, Windows o macOS.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportDeviceCalendar', 'ייבוא מיומן המכשיר', 'he'),
  ('calendarSyncConnectDevice', 'חיבור יומן המכשיר', 'he'),
  ('calendarSyncNoCalendarsDevice', 'לא נמצאו יומני מכשיר במכשיר זה.', 'he'),
  ('calendarSyncDeviceWebNotSupported', 'ייבוא מיומן המכשיר אינו זמין בווב. השתמש/י ב-Android, iOS, Windows או macOS.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
