-- Migration: Distinguish an explicit language choice from an auto-derived one.
--
-- Purpose:
--   The app must start in the device's UI language when the user has never
--   chosen a language, and in English when the device language isn't shipped.
--   users.preferred_language alone cannot answer "did the user choose this?"
--   because:
--     1. the column has DEFAULT 'en', so every signup row starts out holding
--        a language nobody picked;
--     2. the client seeds the column with the resolved UI language so
--        notifications/broadcasts target the right locale.
--   Both are legitimate values, but neither is a choice — and today one of
--   them could win over the device language on startup (or race it back to
--   'en' after a profile save).
--
--   preferred_language_explicit closes that gap:
--     * false -> the value is a seed/default; the client resolves the UI
--       language from the device and may re-seed the column freely.
--     * true  -> the user picked this language in-app; it wins over the
--       device locale on every start and syncs across devices.
--
-- Backfill:
--   Existing 'es'/'he' rows are languages users are actively using (either
--   seeded from their device or picked in-app — indistinguishable at this
--   point), so they are preserved as explicit. Existing 'en' rows are left
--   non-explicit: they are indistinguishable from the untouched column
--   default, which is exactly the value that used to override the device
--   language. Users who did explicitly pick English keep it on their current
--   device (the local SharedPreferences choice still wins); only a fresh
--   install falls back to the device language, which is the intended
--   behavior of this change.

BEGIN;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS preferred_language_explicit boolean NOT NULL DEFAULT false;

UPDATE public.users
SET preferred_language_explicit = true
WHERE lower(btrim(preferred_language)) IN ('es', 'he');

COMMENT ON COLUMN public.users.preferred_language_explicit IS
  'true when the user picked preferred_language in-app; false when it is a device-derived seed or the column default. Only explicit values override the device UI language on startup.';

COMMIT;
