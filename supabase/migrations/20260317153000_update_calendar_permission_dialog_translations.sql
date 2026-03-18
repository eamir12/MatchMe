BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncPermissionActionOpenAppSettings', 'Open App Settings', 'en'),
  ('calendarSyncPermissionActionImportOnline', 'Import Events from Online Account', 'en'),
  ('calendarSyncPermissionActionClose', 'Close', 'en'),
  ('calendarSyncPermissionSettingsGuide', 'To import events from your device calendar, tap Open App Settings. In MatchMe settings, open Permissions, open Calendar, then move the dot to Allow.', 'en'),
  ('calendarSyncPermissionBlockedSettingsGuide', 'Calendar permission is currently blocked by your device. Tap Open App Settings. In MatchMe settings, open Permissions, open Calendar, then move the dot to Allow.', 'en'),
  ('calendarSyncPermissionBlockedSettingsGuideAndroid', 'Calendar permission is currently blocked by your device. Tap Open App Settings. In MatchMe settings, open Permissions, open Calendar, then move the dot to Allow.', 'en'),
  ('calendarSyncPermissionBlockedSettingsGuideIos', 'Calendar permission is currently blocked by your device. Tap Open App Settings. In MatchMe settings, open Permissions, open Calendar, then move the dot to Allow.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncPermissionActionOpenAppSettings', 'Abrir configuración de la app', 'es'),
  ('calendarSyncPermissionActionImportOnline', 'Importar eventos desde cuenta en línea', 'es'),
  ('calendarSyncPermissionActionClose', 'Cerrar', 'es'),
  ('calendarSyncPermissionSettingsGuide', 'Para importar eventos del calendario del dispositivo, toca Abrir configuración de la app. En la configuración de MatchMe, abre Permisos, abre Calendario y luego mueve el punto a Permitir.', 'es'),
  ('calendarSyncPermissionBlockedSettingsGuide', 'El permiso de calendario está bloqueado en tu dispositivo. Toca Abrir configuración de la app. En la configuración de MatchMe, abre Permisos, abre Calendario y luego mueve el punto a Permitir.', 'es'),
  ('calendarSyncPermissionBlockedSettingsGuideAndroid', 'El permiso de calendario está bloqueado en tu dispositivo. Toca Abrir configuración de la app. En la configuración de MatchMe, abre Permisos, abre Calendario y luego mueve el punto a Permitir.', 'es'),
  ('calendarSyncPermissionBlockedSettingsGuideIos', 'El permiso de calendario está bloqueado en tu dispositivo. Toca Abrir configuración de la app. En la configuración de MatchMe, abre Permisos, abre Calendario y luego mueve el punto a Permitir.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncPermissionActionOpenAppSettings', 'פתח/י הגדרות אפליקציה', 'he'),
  ('calendarSyncPermissionActionImportOnline', 'ייבוא אירועים מחשבון אונליין', 'he'),
  ('calendarSyncPermissionActionClose', 'סגירה', 'he'),
  ('calendarSyncPermissionSettingsGuide', 'כדי לייבא אירועים מיומן המכשיר, לחצו על פתיחת הגדרות אפליקציה. בהגדרות של MatchMe פתחו הרשאות, פתחו יומן, ואז הזיזו את הנקודה אל "אפשר".', 'he'),
  ('calendarSyncPermissionBlockedSettingsGuide', 'הרשאת היומן חסומה כרגע במכשיר. לחצו על פתיחת הגדרות אפליקציה. בהגדרות של MatchMe פתחו הרשאות, פתחו יומן, ואז הזיזו את הנקודה אל "אפשר".', 'he'),
  ('calendarSyncPermissionBlockedSettingsGuideAndroid', 'הרשאת היומן חסומה כרגע במכשיר. לחצו על פתיחת הגדרות אפליקציה. בהגדרות של MatchMe פתחו הרשאות, פתחו יומן, ואז הזיזו את הנקודה אל "אפשר".', 'he'),
  ('calendarSyncPermissionBlockedSettingsGuideIos', 'הרשאת היומן חסומה כרגע במכשיר. לחצו על פתיחת הגדרות אפליקציה. בהגדרות של MatchMe פתחו הרשאות, פתחו יומן, ואז הזיזו את הנקודה אל "אפשר".', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
