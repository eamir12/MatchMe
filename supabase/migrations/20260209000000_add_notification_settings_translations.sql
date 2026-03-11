-- supabase/migrations/20260209000000_add_notification_settings_translations.sql
-- Migration: Add notification settings translations
-- Purpose: Add localized strings for notification preferences settings

BEGIN;

-- Add translations for notification settings
-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsNotifications', 'Notifications', 'en'),
  ('settingsNotificationsTitle', 'Notification Preferences', 'en'),
  ('settingsNotificationsDesc', 'Manage how and when you receive notifications', 'en'),
  ('settingsNotificationTypes', 'Notification Types', 'en'),
  ('settingsNotificationsChatMessages', 'Chat Messages', 'en'),
  ('settingsNotificationsChatMessagesDesc', 'Get notified when you receive new messages', 'en'),
  ('settingsNotificationsMatchExpiry', 'Match Expiry Alerts', 'en'),
  ('settingsNotificationsMatchExpiryDesc', 'Get notified when matches are about to expire', 'en'),
  ('settingsNotificationsAdmin', 'Admin Announcements', 'en'),
  ('settingsNotificationsAdminDesc', 'Receive important announcements from the app', 'en'),
  ('settingsNotificationPreferences', 'Notification Preferences', 'en'),
  ('settingsNotificationsSound', 'Sound', 'en'),
  ('settingsNotificationsSoundDesc', 'Play sound for notifications', 'en'),
  ('settingsNotificationsVibration', 'Vibration', 'en'),
  ('settingsNotificationsVibrationDesc', 'Vibrate for notifications', 'en'),
  ('settingsNotificationsInApp', 'In-App Notifications', 'en'),
  ('settingsNotificationsInAppDesc', 'Show notifications within the app', 'en'),
  ('settingsNotificationsInfo', 'You can manage system notification permissions in your device settings.', 'en'),
  ('settingsNotificationsSettingsDesc', 'Control notification preferences', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsNotifications', 'Notificaciones', 'es'),
  ('settingsNotificationsTitle', 'Preferencias de notificaciones', 'es'),
  ('settingsNotificationsDesc', 'Controla cómo y cuándo recibes notificaciones', 'es'),
  ('settingsNotificationTypes', 'Tipos de notificaciones', 'es'),
  ('settingsNotificationsChatMessages', 'Mensajes de chat', 'es'),
  ('settingsNotificationsChatMessagesDesc', 'Recibe notificaciones cuando recibes nuevos mensajes', 'es'),
  ('settingsNotificationsMatchExpiry', 'Alertas de coincidencia vencida', 'es'),
  ('settingsNotificationsMatchExpiryDesc', 'Recibe notificaciones cuando las coincidencias están a punto de vencer', 'es'),
  ('settingsNotificationsAdmin', 'Anuncios de administración', 'es'),
  ('settingsNotificationsAdminDesc', 'Recibe anuncios importantes de la aplicación', 'es'),
  ('settingsNotificationPreferences', 'Preferencias de notificaciones', 'es'),
  ('settingsNotificationsSound', 'Sonido', 'es'),
  ('settingsNotificationsSoundDesc', 'Reproducir sonido para notificaciones', 'es'),
  ('settingsNotificationsVibration', 'Vibración', 'es'),
  ('settingsNotificationsVibrationDesc', 'Vibrar para notificaciones', 'es'),
  ('settingsNotificationsInApp', 'Notificaciones en la aplicación', 'es'),
  ('settingsNotificationsInAppDesc', 'Mostrar notificaciones dentro de la aplicación', 'es'),
  ('settingsNotificationsInfo', 'Puedes gestionar los permisos de notificaciones del sistema en la configuración de tu dispositivo.', 'es'),
  ('settingsNotificationsSettingsDesc', 'Controla las preferencias de notificaciones', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsNotifications', 'התראות', 'he'),
  ('settingsNotificationsTitle', 'העדפות התראות', 'he'),
  ('settingsNotificationsDesc', 'שלוט כיצד ומתי אתה מקבל התראות', 'he'),
  ('settingsNotificationTypes', 'סוגי התראות', 'he'),
  ('settingsNotificationsChatMessages', 'הודעות צ''אט', 'he'),
  ('settingsNotificationsChatMessagesDesc', 'קבל התראות כאשר אתה מקבל הודעות חדשות', 'he'),
  ('settingsNotificationsMatchExpiry', 'התראות תוקף התאמה', 'he'),
  ('settingsNotificationsMatchExpiryDesc', 'קבל התראות כאשר התאמות עומדות לתוקף', 'he'),
  ('settingsNotificationsAdmin', 'הודעות ניהול', 'he'),
  ('settingsNotificationsAdminDesc', 'קבל הודעות חשובות מהאפליקציה', 'he'),
  ('settingsNotificationPreferences', 'העדפות התראות', 'he'),
  ('settingsNotificationsSound', 'קול', 'he'),
  ('settingsNotificationsSoundDesc', 'השמע קול לתראות', 'he'),
  ('settingsNotificationsVibration', 'רטט', 'he'),
  ('settingsNotificationsVibrationDesc', 'רטוט לתראות', 'he'),
  ('settingsNotificationsInApp', 'התראות בתוך האפליקציה', 'he'),
  ('settingsNotificationsInAppDesc', 'הצג התראות בתוך האפליקציה', 'he'),
  ('settingsNotificationsInfo', 'אתה יכול לנהל הרשאות ההתראות של המערכת בהגדרות המכשיר שלך.', 'he'),
  ('settingsNotificationsSettingsDesc', 'שלוט בהעדפות התראות', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
