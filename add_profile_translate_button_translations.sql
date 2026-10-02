-- Add translations for user-initiated bio/occupation translation buttons
-- Used by match_profile_screen.dart (_TranslatableProfileText):
-- profileTranslateButton = "Translate", profileShowOriginalButton = "Show original"
-- English fallback lives in lib/providers/locale_provider.dart _defaultTranslations.

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileTranslateButton', 'Translate'),
  ('es', 'profileTranslateButton', 'Traducir'),
  ('he', 'profileTranslateButton', 'תרגם'),
  ('en', 'profileShowOriginalButton', 'Show original'),
  ('es', 'profileShowOriginalButton', 'Mostrar original'),
  ('he', 'profileShowOriginalButton', 'הצג מקור')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
