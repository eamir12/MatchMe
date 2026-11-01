-- Migration: caption for the own-profile status band
--
-- The three public status chips (Primary Photo Verified / New here /
-- Profile Complete) moved out of the Name row into one band under the
-- photos on the own-profile screen. A caption above the band tells the
-- owner the chips are visible to other users.
--
-- English fallback lives in lib/providers/locale_provider.dart
-- (_defaultTranslations.profileBadgesShownToOthers).
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'profileBadgesShownToOthers', $$Shown to others$$),
  -- Spanish
  ('es', 'profileBadgesShownToOthers', $$Visible para otros$$),
  -- Hebrew
  ('he', 'profileBadgesShownToOthers', $$מוצג לאחרים$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
