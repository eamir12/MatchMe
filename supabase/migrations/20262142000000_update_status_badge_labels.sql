-- Migration: Relabel the profile status chips
-- Purpose:
--   * The public completeness chip used to read just "Complete", which was
--     too vague next to the other status chips. It now reads
--     "Profile Complete".
--   * The verified chip used to read just "Verified", which implied the
--     whole profile was checked. Only the primary photo is verified, so it
--     now reads "Primary Photo Verified".
-- Both chips are rendered next to "New Here", so all three status marks
-- now carry an explicit label.
-- English fallbacks live in lib/providers/locale_provider.dart::_defaultTranslations.

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'profileCompletionBadge', $$Profile Complete$$),
  ('en', 'profileVerifiedBadge', $$Primary Photo Verified$$),
  ('en', 'profileVerifiedBadgeFemale', $$Primary Photo Verified$$),
  ('en', 'profileVerifiedBadgeNeutral', $$Primary Photo Verified$$),
  -- Spanish
  ('es', 'profileCompletionBadge', $$Perfil completo$$),
  ('es', 'profileVerifiedBadge', $$Foto principal verificada$$),
  ('es', 'profileVerifiedBadgeFemale', $$Foto principal verificada$$),
  ('es', 'profileVerifiedBadgeNeutral', $$Foto principal verificada$$),
  -- Hebrew
  ('he', 'profileCompletionBadge', $$פרופיל מלא$$),
  ('he', 'profileVerifiedBadge', $$תמונה ראשית מאומתת$$),
  ('he', 'profileVerifiedBadgeFemale', $$תמונה ראשית מאומתת$$),
  ('he', 'profileVerifiedBadgeNeutral', $$תמונה ראשית מאומתת$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
