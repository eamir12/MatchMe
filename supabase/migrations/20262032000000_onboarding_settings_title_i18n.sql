-- Onboarding tour: localize the settings chapter header.
-- The chapter covers the whole settings screen now, so its title follows
-- the UI language (Hebrew: הגדרות) instead of showing English everywhere.
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingChapterSettings', 'Settings'),
  ('es', 'onboardingChapterSettings', 'Configuración'),
  ('he', 'onboardingChapterSettings', 'הגדרות')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
