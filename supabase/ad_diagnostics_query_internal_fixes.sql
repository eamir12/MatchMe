-- ============================================
-- FIX FOR INTERNAL (SPONSORED) ADS:
-- ============================================

-- Enable internal ads master toggle:
-- UPDATE public.app_config SET config_value = 'true'::jsonb WHERE config_key = 'ads.internal.enabled';

-- Add profile_inline to internal allowed placements:
/*
-- First check current value
SELECT config_key, config_value::jsonb 
FROM public.app_config 
WHERE config_key = 'ads.internal.allowed_placements';

-- Then update to include profile_inline (merge with existing)
UPDATE public.app_config 
SET config_value = (config_value::jsonb || '["profile_inline"]'::jsonb)::text,
    updated_at = NOW()
WHERE config_key = 'ads.internal.allowed_placements'
  AND NOT (config_value::jsonb @> '["profile_inline"]'::jsonb);

-- Or set default if config doesn't exist:
INSERT INTO public.app_config (config_key, config_value, config_type, category, description)
VALUES ('ads.internal.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]', 'array', 'ads', 'Allowed placements for internal ads')
ON CONFLICT (config_key) DO UPDATE 
SET config_value = EXCLUDED.config_value,
    updated_at = NOW()
WHERE NOT (public.app_config.config_value::jsonb @> '["profile_inline"]'::jsonb);
*/

-- Enable sponsored cards:
-- UPDATE public.app_config SET config_value = 'true'::jsonb WHERE config_key = 'ads.internal.sponsored_cards_enabled';

-- Copy home_inline creatives to profile_inline (create new creatives with profile placement):
/*
INSERT INTO public.ad_creatives (campaign_id, placement, platform, image_url, headline_key, body_key, cta_key, sponsor_name_key, sort_priority, is_active)
SELECT 
    cr.campaign_id,
    'profile_inline' as placement,
    cr.platform,
    cr.image_url,
    cr.headline_key,
    cr.body_key,
    cr.cta_key,
    cr.sponsor_name_key,
    cr.sort_priority,
    true as is_active
FROM public.ad_creatives cr
JOIN public.ad_campaigns c ON c.id = cr.campaign_id
WHERE cr.placement = 'home_inline'
  AND cr.is_active = true
  AND c.is_active = true
  AND NOT EXISTS (
      SELECT 1 FROM public.ad_creatives existing
      WHERE existing.campaign_id = cr.campaign_id
        AND existing.placement = 'profile_inline'
        AND existing.platform = cr.platform
  );
*/
