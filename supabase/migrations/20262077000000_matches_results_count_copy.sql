-- Migration: Matches screen result count says "Matches", not "conversations".
--
-- English fallbacks live in _defaultTranslations (lib/providers/locale_provider.dart).
-- Spanish and Hebrew live here, matching the app's three supported locales
-- (en, es, he).

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchesResultsCount', '{count} Matches'),
  ('en', 'matchesResultsCountOf', '{shown} of {total} Matches'),
  ('es', 'matchesResultsCount', '{count} coincidencias'),
  ('es', 'matchesResultsCountOf', '{shown} de {total} coincidencias'),
  ('he', 'matchesResultsCount', '{count} התאמות'),
  ('he', 'matchesResultsCountOf', '{shown} מתוך {total} התאמות')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
