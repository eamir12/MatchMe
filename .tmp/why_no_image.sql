-- ============================================================================
-- Why doesn't the MatchMe card show the image (or headline)? (read-only)
-- Run in the SQL editor. Answers, in order:
--   1. What does the serving RPC actually return for home_inline / android
--      right now? (In the editor auth.uid() is NULL — the RPC deliberately
--      continues as a 'free' tier viewer, so this reflects exactly what the
--      Android app gets.)
--   2. Do the creatives have the image URL saved?
--   3. Do the headline translations exist for the keys the creatives use?
--   4. When did ads.config_version last change (was the epoch bumped)?
-- ============================================================================

-- 1. End-to-end: exactly what the app's fetch returns
SELECT campaign_id, creative_id, platform, destination_url,
       left(coalesce(image_url, ''), 70) AS image_url,
       headline, body, cta_label
FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'android');

-- 2. All creatives of the campaign: image + translation keys
SELECT cr.placement, cr.platform, cr.is_active,
       left(coalesce(cr.image_url, ''), 70) AS image_url,
       cr.headline_key
FROM public.ad_creatives cr
JOIN public.ad_campaigns c ON c.id = cr.campaign_id
WHERE c.internal_name = 'test'
ORDER BY cr.placement, cr.platform;

-- 3. Do the translations exist for the headline keys in use?
SELECT t.locale, t.key, left(t.value, 50) AS value
FROM public.translations t
WHERE t.key IN (
  SELECT DISTINCT cr.headline_key
  FROM public.ad_creatives cr
  JOIN public.ad_campaigns c ON c.id = cr.campaign_id
  WHERE c.internal_name = 'test' AND cr.headline_key <> ''
)
ORDER BY t.key, t.locale;

-- 4. Epoch state
SELECT config_key, config_value, updated_at
FROM public.app_config
WHERE config_key = 'ads.config_version';
