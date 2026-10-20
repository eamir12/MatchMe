-- Migration: Add visual and spoken cues that point users to the verification
-- "Take Photo" action.
-- Purpose: Users did not realise they had to scroll down and tap "Take Photo"
--   to start verification. The action is now pinned to the bottom of the
--   screen, a hint card points at it, and voice guidance speaks the same hint
--   after the intro. English fallbacks live in
--   lib/providers/locale_provider.dart::_defaultTranslations; the DB copy
--   takes precedence so the wording can change without an app release.
-- Reference: pattern from 20262118000000_verification_hand_badge_translations.sql

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'verificationTakePhotoHint', $$Review the requirements, then tap {button} at the bottom of the screen to start.$$),
  ('en', 'voiceGuidanceVerificationTakePhotoHint', $$When you are ready, tap {button} at the bottom of the screen to start.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Spanish
  ('es', 'verificationTakePhotoHint', $$Revisa los requisitos y luego toca {button} en la parte inferior de la pantalla para comenzar.$$),
  ('es', 'voiceGuidanceVerificationTakePhotoHint', $$Cuando estés listo, toca {button} en la parte inferior de la pantalla para comenzar.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Hebrew
  ('he', 'verificationTakePhotoHint', $$עברו על הדרישות, ואז הקישו על {button} בתחתית המסך כדי להתחיל.$$),
  ('he', 'voiceGuidanceVerificationTakePhotoHint', $$כשאתם מוכנים, הקישו על {button} בתחתית המסך כדי להתחיל.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
