-- Migration: Cross-device onboarding tour state + section tour translations.
--
-- 1. users.onboarding_tour_state — account-level record of which onboarding
--    tour experiences the member already saw, so a member who installs the
--    app on another device is never auto-shown the tour again. Shape:
--      {
--        "version": 2,
--        "core_seen_at": "<ISO-8601 UTC>",
--        "sections": { "<sectionId>": "<ISO-8601 UTC>", ... }
--      }
--    The client (OnboardingIntroService) writes it best-effort: local
--    SharedPreferences stay the offline source of truth, and the server copy
--    is consulted when the local device has no record (fresh install).
--    Null means "never stored" (pre-migration accounts backfill it lazily).
-- 2. Translations for the per-section tour offer banner and the Settings
--    "App tour" hub (basics + section replay list). English values must stay
--    byte-identical to the fallbacks in lib/providers/locale_provider.dart
--    (scripts/check_onboarding_translations.js).
-- Idempotent: safe to re-run.

BEGIN;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS onboarding_tour_state jsonb;

COMMENT ON COLUMN public.users.onboarding_tour_state IS
  'Device-independent onboarding tour progress: {"version": 2, "core_seen_at": "<iso>", "sections": {"<sectionId>": "<iso>"}}. Null = never stored (client backfills from local prefs).';

-- English
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'settingsAppTourDesc', 'Replay the guided intro or a specific section.'),
  ('en', 'onboardingTourBasics', 'The basics'),
  ('en', 'onboardingTourBasicsDesc', 'A quick overview of how MatchMe works.'),
  ('en', 'onboardingTourSections', 'Section tours'),
  ('en', 'onboardingSectionPromptBody', 'New here? Watch a 30-second guided tour of this screen.'),
  ('en', 'onboardingSectionPromptStart', 'Show me'),
  ('en', 'onboardingSectionPromptDismiss', 'No thanks')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'settingsAppTourDesc', 'Vuelve a ver la introducción guiada o una sección concreta.'),
  ('es', 'onboardingTourBasics', 'Lo básico'),
  ('es', 'onboardingTourBasicsDesc', 'Un repaso rápido de cómo funciona MatchMe.'),
  ('es', 'onboardingTourSections', 'Recorridos por sección'),
  ('es', 'onboardingSectionPromptBody', '¿Primera vez aquí? Mira un recorrido guiado de 30 segundos por esta pantalla.'),
  ('es', 'onboardingSectionPromptStart', 'Muéstrame'),
  ('es', 'onboardingSectionPromptDismiss', 'No, gracias')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'settingsAppTourDesc', 'הצג שוב את ההדרכה המונחית או מדור מסוים.'),
  ('he', 'onboardingTourBasics', 'היסודות'),
  ('he', 'onboardingTourBasicsDesc', 'סקירה קצרה של איך MatchMe עובד.'),
  ('he', 'onboardingTourSections', 'סיורים לפי מדור'),
  ('he', 'onboardingSectionPromptBody', 'פעם ראשונה כאן? צפו בסיור מונחה של 30 שניות במסך הזה.'),
  ('he', 'onboardingSectionPromptStart', 'הראה לי'),
  ('he', 'onboardingSectionPromptDismiss', 'לא תודה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
