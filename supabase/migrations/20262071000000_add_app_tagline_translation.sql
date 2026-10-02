-- App tagline translations (en/es/he)
-- Shown beneath the logo on the startup loader
-- (lib/widgets/startup_loader.dart).
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart: the DB copy takes precedence once seeded, so the
-- tagline can be reworded in the database without an app release, while the
-- code fallback keeps pre-migration/offline clients working.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'appTagline', 'Connecting people, naturally!'),
  ('es', 'appTagline', 'Conectando personas, de forma natural!'),
  ('he', 'appTagline', 'מחברים בני אדם, בטבעיות!')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
