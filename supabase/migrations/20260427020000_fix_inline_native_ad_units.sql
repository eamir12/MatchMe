-- Fix inline ad units: deactivate native ads for inline placements
-- The app currently uses banner format only for inline placements
-- Having both banner and native causes the native ID to sometimes be returned,
-- which fails when the widget tries to load it as a banner

BEGIN;

-- Deactivate native ad units for inline placements
-- These are conflicting with the banner ads for the same placements
UPDATE public.ad_units
SET is_active = false
WHERE ad_format = 'native'
  AND placement IN ('home_inline', 'matches_inline', 'chats_inline', 'events_inline')
  AND platform IN ('android', 'ios');

-- Verify the fix: show active ad units for inline placements
SELECT placement, platform, ad_format, ad_unit_id, is_active
FROM public.ad_units
WHERE placement IN ('home_inline', 'matches_inline', 'chats_inline', 'events_inline')
  AND platform = 'android'
  AND is_active = true
ORDER BY placement, ad_format;

COMMIT;
