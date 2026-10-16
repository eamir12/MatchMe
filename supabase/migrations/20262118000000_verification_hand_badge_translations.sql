-- Migration: Add translations for the capture hand badge ("Left hand" / "Right hand")
-- Purpose: The hand badge under the capture gesture icon previously reused the
--   short sentence fragments 'verificationCaptureHandLeft'/'...Right' (values
--   'left'/'right'), which read the same inside the "use your {hand} hand"
--   template. The badge now uses dedicated keys with full display text so the
--   pill reads "Left hand" / "Right hand" in every language. English fallbacks
--   are in lib/providers/locale_provider.dart::_defaultTranslations, and the
--   capture page falls back to its built-in English when keys are absent.
-- Reference: See supabase/migrations/20262117000001_add_profile_completeness_translations.sql for pattern.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'verificationCaptureHandLeftBadge', $$Left hand$$),
  ('en', 'verificationCaptureHandRightBadge', $$Right hand$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Spanish
  ('es', 'verificationCaptureHandLeftBadge', $$Mano izquierda$$),
  ('es', 'verificationCaptureHandRightBadge', $$Mano derecha$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Hebrew
  ('he', 'verificationCaptureHandLeftBadge', $$יד שמאל$$),
  ('he', 'verificationCaptureHandRightBadge', $$יד ימין$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
