-- supabase/migrations/20260708000000_add_match_preferences_translations.sql
-- Migration: Add Match Preferences translations
-- Purpose: Localize keys for the redesigned Match Preferences settings screen.

BEGIN;

-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('generalSaved', 'Saved', 'en'),
  ('generalDiscard', 'Discard', 'en'),
  ('settingsCopyFromProfile', 'Copy from my profile', 'en'),
  ('settingsCopyFromProfileHint', 'Use your own profile values as filters for this intent.', 'en'),
  ('settingsUnsavedChangesTitle', 'Unsaved Changes', 'en'),
  ('settingsUnsavedChangesMessage', 'You have unsaved changes. What would you like to do?', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('generalSaved', 'Guardado', 'es'),
  ('generalDiscard', 'Descartar', 'es'),
  ('settingsCopyFromProfile', 'Copiar de mi perfil', 'es'),
  ('settingsCopyFromProfileHint', 'Usa los valores de tu propio perfil como filtros para esta intención.', 'es'),
  ('settingsUnsavedChangesTitle', 'Cambios sin guardar', 'es'),
  ('settingsUnsavedChangesMessage', 'Tienes cambios sin guardar. ¿Qué te gustaría hacer?', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('generalSaved', 'נשמר', 'he'),
  ('generalDiscard', 'בטל שינויים', 'he'),
  ('settingsCopyFromProfile', 'העתק מהפרופיל שלי', 'he'),
  ('settingsCopyFromProfileHint', 'השתמש בערכים מהפרופיל שלך כמסננים עבור כוונה זו.', 'he'),
  ('settingsUnsavedChangesTitle', 'שינויים שלא נשמרו', 'he'),
  ('settingsUnsavedChangesMessage', 'יש לך שינויים שלא נשמרו. מה תרצה לעשות?', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
