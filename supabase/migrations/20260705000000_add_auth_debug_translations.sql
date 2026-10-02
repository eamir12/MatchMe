-- supabase/migrations/20260705000000_add_auth_debug_translations.sql
-- Migration: Add auth debug dialog translations
-- Purpose: Localize debug sign-out reason dialog in auth_screen

BEGIN;

-- Add translations for auth debug dialog
-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('authDebugLastSignOut', 'Debug: Last Sign-Out', 'en'),
  ('authDebugReason', 'Reason', 'en'),
  ('authDebugSource', 'Source', 'en'),
  ('authDebugTime', 'Time', 'en'),
  ('authDebugNoSignOutReason', 'No sign-out reason recorded.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('authDebugLastSignOut', 'Depuración: Último cierre de sesión', 'es'),
  ('authDebugReason', 'Motivo', 'es'),
  ('authDebugSource', 'Fuente', 'es'),
  ('authDebugTime', 'Hora', 'es'),
  ('authDebugNoSignOutReason', 'No se registró ningún motivo de cierre de sesión.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('authDebugLastSignOut', 'ניפוי באג נתונים: התנתקות אחרונה', 'he'),
  ('authDebugReason', 'סיבה', 'he'),
  ('authDebugSource', 'מקור', 'he'),
  ('authDebugTime', 'זמן', 'he'),
  ('authDebugNoSignOutReason', 'לא נרשמה סיבה להתנתקות.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
