-- supabase/migrations/20260703000001_condense_enforcement_ui_translations.sql
-- Migration: Add shorter, more concise enforcement UI translations
-- Purpose: Replace long button labels with shorter versions that fit better in the UI
-- Also add condensed layout labels to reduce screen repetition

BEGIN;

-- Add translations for shorter enforcement button labels
-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleShort', 'Include all', 'en'),
  ('settingsEnforcementStrictShort', 'Exact match', 'en'),
  ('settingsEnforcementTooltipShort', 'Include all: Shows matches outside your preferences too. Exact match: Only shows matches within your exact preferences.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleShort', 'Incluir todos', 'es'),
  ('settingsEnforcementStrictShort', 'Coincidencia exacta', 'es'),
  ('settingsEnforcementTooltipShort', 'Incluir todos: Muestra coincidencias fuera de tus preferencias. Coincidencia exacta: Solo muestra coincidencias dentro de tus preferencias exactas.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleShort', 'כלול הכל', 'he'),
  ('settingsEnforcementStrictShort', 'התאמה מדויקת', 'he'),
  ('settingsEnforcementTooltipShort', 'כלול הכל: מציג התאמות גם מחוץ להעדפות שלך. התאמה מדויקת: מציג רק התאמות בתוך ההעדפות המדויקות שלך.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
