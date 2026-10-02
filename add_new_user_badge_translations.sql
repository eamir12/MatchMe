-- Add translations for new user badge
-- This migration adds localization entries for the "New here!" badge text
-- Includes masculine, feminine, and neutral/non-binary versions for gender-sensitive languages

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileNewUserBadge', 'New here!'),
  ('es', 'profileNewUserBadge', '¡Nuevo aquí!'),
  ('he', 'profileNewUserBadge', 'חדש כאן!'),
  ('en', 'profileNewUserBadgeFemale', 'New here!'),
  ('es', 'profileNewUserBadgeFemale', '¡Nueva aquí!'),
  ('he', 'profileNewUserBadgeFemale', 'חדשה כאן!'),
  ('en', 'profileNewUserBadgeNeutral', 'New here!'),
  ('es', 'profileNewUserBadgeNeutral', '¡Nuevamente aquí!'),
  ('he', 'profileNewUserBadgeNeutral', 'חדש/ה כאן!')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
