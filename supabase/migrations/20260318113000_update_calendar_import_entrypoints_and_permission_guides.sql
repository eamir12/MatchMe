BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportOnlineProviders', 'Import from Online Providers', 'en'),
  ('eventsImportGoogle', 'Import from Google', 'en'),
  ('eventsImportOutlook', 'Import from Outlook', 'en'),
  ('eventsImportApple', 'Import from Apple', 'en'),
  ('calendarSyncPermissionActionImportOnline', 'Import from Online Providers', 'en'),
  ('calendarSyncPermissionSettingsGuide', 'To import from your device calendar, tap Open App Settings and enable Calendar permission for MatchMe.', 'en'),
  ('calendarSyncPermissionBlockedSettingsGuide', 'Calendar permission is currently blocked. Tap Open App Settings and enable Calendar permission for MatchMe.', 'en'),
  ('calendarSyncPermissionBlockedSettingsGuideAndroid', 'Calendar permission is currently blocked on Android. Tap Open App Settings, then Permissions → Calendar, and choose Allow.', 'en'),
  ('calendarSyncPermissionBlockedSettingsGuideIos', 'Calendar permission is currently blocked on iOS. Tap Open App Settings, then Calendars, and enable access for MatchMe.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportOnlineProviders', 'Importar desde proveedores en línea', 'es'),
  ('eventsImportGoogle', 'Importar desde Google', 'es'),
  ('eventsImportOutlook', 'Importar desde Outlook', 'es'),
  ('eventsImportApple', 'Importar desde Apple', 'es'),
  ('calendarSyncPermissionActionImportOnline', 'Importar desde proveedores en línea', 'es'),
  ('calendarSyncPermissionSettingsGuide', 'Para importar desde el calendario del dispositivo, toca Abrir configuración de la app y habilita el permiso de Calendario para MatchMe.', 'es'),
  ('calendarSyncPermissionBlockedSettingsGuide', 'El permiso de Calendario está bloqueado. Toca Abrir configuración de la app y habilita el permiso de Calendario para MatchMe.', 'es'),
  ('calendarSyncPermissionBlockedSettingsGuideAndroid', 'El permiso de Calendario está bloqueado en Android. Toca Abrir configuración de la app, luego Permisos → Calendario y elige Permitir.', 'es'),
  ('calendarSyncPermissionBlockedSettingsGuideIos', 'El permiso de Calendario está bloqueado en iOS. Toca Abrir configuración de la app, luego Calendarios y habilita el acceso para MatchMe.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('eventsImportOnlineProviders', 'ייבוא מספקים מקוונים', 'he'),
  ('eventsImportGoogle', 'ייבוא מ-Google', 'he'),
  ('eventsImportOutlook', 'ייבוא מ-Outlook', 'he'),
  ('eventsImportApple', 'ייבוא מ-Apple', 'he'),
  ('calendarSyncPermissionActionImportOnline', 'ייבוא מספקים מקוונים', 'he'),
  ('calendarSyncPermissionSettingsGuide', 'כדי לייבא מיומן המכשיר, לחצו על פתיחת הגדרות אפליקציה והפעילו הרשאת יומן עבור MatchMe.', 'he'),
  ('calendarSyncPermissionBlockedSettingsGuide', 'הרשאת היומן חסומה כרגע. לחצו על פתיחת הגדרות אפליקציה והפעילו הרשאת יומן עבור MatchMe.', 'he'),
  ('calendarSyncPermissionBlockedSettingsGuideAndroid', 'הרשאת היומן חסומה ב-Android. לחצו על פתיחת הגדרות אפליקציה, ואז הרשאות ← יומן, ובחרו אפשר.', 'he'),
  ('calendarSyncPermissionBlockedSettingsGuideIos', 'הרשאת היומן חסומה ב-iOS. לחצו על פתיחת הגדרות אפליקציה, ואז לוחות שנה, והפעילו גישה עבור MatchMe.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
