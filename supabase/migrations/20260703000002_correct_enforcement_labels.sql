-- supabase/migrations/20260703000002_correct_enforcement_labels.sql
-- Migration: Correct enforcement labels to accurately reflect matching behavior
-- Purpose: Replace misleading "Include all" label with accurate description
-- The flexible mode only allows matches outside preferences when no compliant candidates exist

BEGIN;

-- Update translations with accurate labels
-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleShort', 'Allow exceptions', 'en'),
  ('settingsEnforcementStrictShort', 'Strict only', 'en'),
  ('settingsEnforcementTooltipShort', 'Strict only: Only shows matches within your exact preferences. Allow exceptions: Shows matches outside preferences when no better options are available.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleShort', 'Permitir excepciones', 'es'),
  ('settingsEnforcementStrictShort', 'Solo estricto', 'es'),
  ('settingsEnforcementTooltipShort', 'Solo estricto: Solo muestra coincidencias dentro de tus preferencias exactas. Permitir excepciones: Muestra coincidencias fuera de tus preferencias cuando no hay mejores opciones disponibles.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleShort', 'אפשר חריגות', 'he'),
  ('settingsEnforcementStrictShort', 'רק מדויק', 'he'),
  ('settingsEnforcementTooltipShort', 'רק מדויק: מציג רק התאמות בתוך ההעדפות המדויקות שלך. אפשר חריגות: מציג התאמות מחוץ להעדפות כאשר אין אפשרויות טובות יותר זמינות.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
