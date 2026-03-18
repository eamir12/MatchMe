BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportDeviceCalendar', 'Import from Device Calendar', 'en'),
  ('calendarSyncConnectDevice', 'Connect Device Calendar', 'en'),
  ('calendarSyncNoCalendarsDevice', 'No device calendars were found on this device.', 'en'),
  ('calendarSyncDeviceUnknownAccount', 'Unknown account', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportDeviceCalendar', 'Importar desde el calendario del dispositivo', 'es'),
  ('calendarSyncConnectDevice', 'Conectar calendario del dispositivo', 'es'),
  ('calendarSyncNoCalendarsDevice', 'No se encontraron calendarios del dispositivo en este dispositivo.', 'es'),
  ('calendarSyncDeviceUnknownAccount', 'Cuenta desconocida', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportDeviceCalendar', 'ייבוא מיומן המכשיר', 'he'),
  ('calendarSyncConnectDevice', 'חיבור יומן המכשיר', 'he'),
  ('calendarSyncNoCalendarsDevice', 'לא נמצאו יומני מכשיר במכשיר זה.', 'he'),
  ('calendarSyncDeviceUnknownAccount', 'חשבון לא ידוע', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
