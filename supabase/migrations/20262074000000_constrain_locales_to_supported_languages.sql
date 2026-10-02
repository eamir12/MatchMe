-- Migration: Constrain the app to its three shipped languages (en, es, he).
--
-- Purpose:
--   MatchMe currently ships three translations: English, Spanish and Hebrew.
--   Nothing enforced that, so a client could write an arbitrary
--   users.preferred_language value and the translations table could accumulate
--   rows for locales the app cannot render. Readers then fell through to
--   English inconsistently — some places normalized, some queried a locale
--   that had no rows.
--
--   This migration makes the constraint systemic rather than per-reader:
--     1. Normalizes any out-of-range preferred_language to 'en'.
--     2. Deletes any out-of-range translations rows (expected to be none).
--     3. Adds CHECK constraints so the database itself rejects anything else.
--
-- Adding a language later is a deliberate act: relax the CHECK, add the
-- translation rows, and update the AppLanguage list in
-- lib/providers/locale_provider.dart plus the _pushStrings table in
-- supabase/functions/push-message/index.ts.

BEGIN;

-- 1) Normalize users.preferred_language before constraining it.
--    Handles '', NULL, and any non-supported tag (including regional
--    variants like 'es-419' or 'he-IL', which no longer match the CHECK).
UPDATE public.users
SET preferred_language = 'en'
WHERE preferred_language IS NULL
   OR lower(btrim(preferred_language)) NOT IN ('en', 'es', 'he');

-- 2) Drop translations for locales the app does not ship.
--    Safety net: the audit found none, so this should affect 0 rows.
DELETE FROM public.translations
WHERE locale IS NULL
   OR lower(btrim(locale)) NOT IN ('en', 'es', 'he');

-- 3) Enforce it.
ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_preferred_language_supported;
ALTER TABLE public.users
  ADD CONSTRAINT users_preferred_language_supported
  CHECK (lower(btrim(preferred_language)) IN ('en', 'es', 'he'));

ALTER TABLE public.translations
  DROP CONSTRAINT IF EXISTS translations_locale_supported;
ALTER TABLE public.translations
  ADD CONSTRAINT translations_locale_supported
  CHECK (lower(btrim(locale)) IN ('en', 'es', 'he'));

-- 4) Report anything that was normalized or removed, so the change is visible
--    in the migration log rather than silent.
DO $$
DECLARE
  v_normalized int;
  v_deleted int;
BEGIN
  -- The UPDATEs above already ran; recount what is out of range now (expect 0).
  SELECT count(*) INTO v_normalized
  FROM public.users
  WHERE preferred_language IS NULL
     OR lower(btrim(preferred_language)) NOT IN ('en', 'es', 'he');

  SELECT count(*) INTO v_deleted
  FROM public.translations
  WHERE locale IS NULL
     OR lower(btrim(locale)) NOT IN ('en', 'es', 'he');

  RAISE NOTICE 'i18n: users.preferred_language constrained to en/es/he (out-of-range remaining: %)', v_normalized;
  RAISE NOTICE 'i18n: translations.locale constrained to en/es/he (out-of-range remaining: %)', v_deleted;
END;
$$;

COMMIT;
