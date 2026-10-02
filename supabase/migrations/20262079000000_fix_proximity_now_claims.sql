-- Migration: Remove live-proximity "right now" claim from match-type filter.
--
-- Problem:
--   matchTypeFilterProximityBlurb asserted a specific matched person is
--   "Near you now" / "Cerca de ti ahora" / "קרובים אליך עכשיו".
--   We cannot know they are still nearby; the match only proves they were
--   near before. Past tense matches the section label ("How you met" /
--   "Cómo se conocieron" / "איך נפגשו") and the map copy
--   ("You were nearby each other").
--
-- Fix (past/basis, no "now"):
--   en 'Met nearby', es 'Se conocieron cerca', he 'נפגשו בקרבה'.
--
-- Scope is intentionally minimal (this key only). Audit of all other
-- migrations (en "right now", es "ahora/ahora mismo/en este momento",
-- he "עכשיו"):
--   * onboardingBeatHome2 proximity+now (20260920120000, 20262023000000)
--     already superseded by 20262036000000_onboarding_promise_copy.sql
--     ("nearby people and online activity", no "now") - no action.
--   * Remaining "now" hits are legitimate: online presence
--     ("online right now" / "en línea ahora mismo"), system errors
--     ("right now, try again"), CTA buttons ("Verify now" / "Verificar
--     ahora" / "אמת עכשיו"), and inceptive "is now finding"
--     (onboardingBeatFinish1) - no specific live-location claim.
--   * SQL NOW() / comments ignored (not user-facing).
--
-- This upsert also heals DBs where 20262075000000 already applied, since
-- Supabase does not re-run edited migrations. Values match the rewritten
-- 20262075000000 and lib/providers/locale_provider.dart fallback.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchTypeFilterProximityBlurb', 'Met nearby'),
  ('es', 'matchTypeFilterProximityBlurb', 'Se conocieron cerca'),
  ('he', 'matchTypeFilterProximityBlurb', 'נפגשו בקרבה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
