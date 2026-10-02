-- supabase/migrations/20260703000004_add_settings_subsection_descriptions.sql
-- Migration: Add description translations for settings subsection navigation cards
-- Purpose: Add localized descriptions for App Display, Matching, and Account Management cards

BEGIN;

-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsAppDisplayDesc', 'Adjust language, currency, units, time format, and theme.', 'en'),
  ('settingsMatchingDesc', 'Configure match radius, GPS settings, and sharing preferences.', 'en'),
  ('settingsAccountManagementDesc', 'Change your password, update your email, or delete your account.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsAppDisplayDesc', 'Ajusta idioma, moneda, unidades, formato de hora y tema.', 'es'),
  ('settingsMatchingDesc', 'Configura el radio de coincidencia, el GPS y las preferencias de uso compartido.', 'es'),
  ('settingsAccountManagementDesc', 'Cambia tu contraseña, actualiza tu correo o elimina tu cuenta.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsAppDisplayDesc', 'התאם שפה, מטבע, יחידות, פורמט שעה ונושא תצוגה.', 'he'),
  ('settingsMatchingDesc', 'הגדר רדיוס התאמה, הגדרות GPS והעדפות שיתוף.', 'he'),
  ('settingsAccountManagementDesc', 'שנה סיסמה, עדכן אימייל או מחק חשבון.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
