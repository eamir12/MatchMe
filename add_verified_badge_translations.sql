-- Add translations for verified badge
-- This migration adds localization entries for the "Primary Photo Verified"
-- badge text (only the primary photo is verified, so the chip says so).
-- Includes masculine, feminine, and neutral/non-binary versions for gender-sensitive languages

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileVerifiedBadge', 'Primary Photo Verified'),
  ('es', 'profileVerifiedBadge', 'Foto principal verificada'),
  ('he', 'profileVerifiedBadge', 'תמונה ראשית מאומתת'),
  ('en', 'profileVerifiedBadgeFemale', 'Primary Photo Verified'),
  ('es', 'profileVerifiedBadgeFemale', 'Foto principal verificada'),
  ('he', 'profileVerifiedBadgeFemale', 'תמונה ראשית מאומתת'),
  ('en', 'profileVerifiedBadgeNeutral', 'Primary Photo Verified'),
  ('es', 'profileVerifiedBadgeNeutral', 'Foto principal verificada'),
  ('he', 'profileVerifiedBadgeNeutral', 'תמונה ראשית מאומתת')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
