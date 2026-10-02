-- supabase/migrations/20260703000000_improve_enforcement_ui_translations.sql
-- Migration: Add improved enforcement UI translations
-- Purpose: Add clearer, more user-friendly labels for gender/age preference enforcement
-- Replaces "Flexible/Strict" with more descriptive labels based on dating app best practices

BEGIN;

-- Add translations for improved enforcement labels
-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleLabel', 'Show matches outside preferences too', 'en'),
  ('settingsEnforcementStrictLabel', 'Only show matches within preferences', 'en'),
  ('settingsEnforcementTooltip', 'When enabled, you will only see people who match your exact preferences. When disabled, we may show you people slightly outside your range to help you make more connections.', 'en'),
  ('settingsEnforcementImpactFlexible', 'This expands your potential matches', 'en'),
  ('settingsEnforcementImpactStrict', 'This may reduce your match pool', 'en'),
  ('settingsGenderAgePreferencesIntro', 'Set who you would like to see for each of your relationship goals. You can have different preferences for different intents.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleLabel', 'Mostrar coincidencias fuera de las preferencias', 'es'),
  ('settingsEnforcementStrictLabel', 'Mostrar solo coincidencias dentro de las preferencias', 'es'),
  ('settingsEnforcementTooltip', 'Cuando está activado, solo verás personas que coinciden exactamente con tus preferencias. Cuando está desactivado, podemos mostrarte personas ligeramente fuera de tu rango para ayudarte a hacer más conexiones.', 'es'),
  ('settingsEnforcementImpactFlexible', 'Esto expande tus posibles coincidencias', 'es'),
  ('settingsEnforcementImpactStrict', 'Esto puede reducir tu grupo de coincidencias', 'es'),
  ('settingsGenderAgePreferencesIntro', 'Define a quién te gustaría ver para cada uno de tus objetivos de relación. Puedes tener diferentes preferencias para diferentes intenciones.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('settingsEnforcementFlexibleLabel', 'הצג התאמות גם מחוץ להעדפות', 'he'),
  ('settingsEnforcementStrictLabel', 'הצג רק התאמות בתוך ההעדפות', 'he'),
  ('settingsEnforcementTooltip', 'כאשר מופעל, תראה רק אנשים שתואמים בדיוק את ההעדפות שלך. כאשר מושבת, אנו עשויים להציג לך אנשים מעט מחוץ לטווח שלך כדי לעזור לך ליצור חיבורים נוספים.', 'he'),
  ('settingsEnforcementImpactFlexible', 'זה מרחיב את ההתאמות האפשריות שלך', 'he'),
  ('settingsEnforcementImpactStrict', 'זה עשוי להקטין את מאגר ההתאמות שלך', 'he'),
  ('settingsGenderAgePreferencesIntro', 'קבע מי תרצה לראות עבור כל אחד ממטרות הקשר שלך. אתה יכול להיות בעל העדפות שונות עבור כוונות שונות.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
