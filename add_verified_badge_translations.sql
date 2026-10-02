-- Add translations for verified badge
-- This migration adds localization entries for the "Verified" badge text
-- Includes masculine, feminine, and neutral/non-binary versions for gender-sensitive languages

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileVerifiedBadge', 'Verified'),
  ('es', 'profileVerifiedBadge', 'Verificado'),
  ('he', 'profileVerifiedBadge', 'מאומת'),
  ('en', 'profileVerifiedBadgeFemale', 'Verified'),
  ('es', 'profileVerifiedBadgeFemale', 'Verificada'),
  ('he', 'profileVerifiedBadgeFemale', 'מאומתת'),
  ('en', 'profileVerifiedBadgeNeutral', 'Verified'),
  ('es', 'profileVerifiedBadgeNeutral', 'Verificade'),
  ('he', 'profileVerifiedBadgeNeutral', 'מאומת/ת')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
