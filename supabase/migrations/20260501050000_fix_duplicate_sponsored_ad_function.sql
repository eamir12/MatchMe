-- Fix duplicate get_sponsored_ad_for_placement function definitions
-- The function was created multiple times without proper cleanup, causing ambiguity

BEGIN;

-- Drop all versions of the function
DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text, text, text) CASCADE;
DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text, text) CASCADE;

-- Recreate the correct version with all three parameters
CREATE OR REPLACE FUNCTION public.get_sponsored_ad_for_placement(
  p_placement text,
  p_locale text,
  p_platform text
)
RETURNS TABLE (
  campaign_id uuid,
  creative_id uuid,
  placement text,
  platform text,
  destination_url text,
  image_url text,
  sponsor_name text,
  headline text,
  body text,
  cta_label text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_locale text := lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en'));
  v_platform text := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));
  v_allowed_placements jsonb;
  v_allowed_platforms jsonb;
  v_tier text;
BEGIN
  -- Check authentication
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Check if internal ads are enabled
  IF NOT public.app_config_bool('ads.internal.enabled', false) THEN
    RETURN;
  END IF;

  -- Check if sponsored cards are enabled
  IF NOT public.app_config_bool('ads.internal.sponsored_cards_enabled', true) THEN
    RETURN;
  END IF;

  -- Get user's subscription tier
  SELECT COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free')
  INTO v_tier
  FROM public.users
  WHERE id = v_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Check free tier only restriction
  IF public.app_config_bool('ads.internal.free_tier_only', true) AND v_tier != 'free' THEN
    RETURN;
  END IF;

  -- Load master controls with defaults including all placements and platforms
  v_allowed_placements := public.app_config_jsonb('ads.internal.allowed_placements', 
    '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.internal.allowed_platforms', 
    '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb);

  -- Check if requested placement is allowed at master level
  IF NOT (v_allowed_placements ? p_placement) THEN
    RETURN;
  END IF;

  -- Check if requested platform is allowed at master level
  IF NOT (v_allowed_platforms ? v_platform) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    c.id AS campaign_id,
    cr.id AS creative_id,
    cr.placement,
    cr.platform,
    c.destination_url,
    cr.image_url,
    COALESCE(c.advertiser_name, '') AS sponsor_name,
    COALESCE(cr.headline, '') AS headline,
    COALESCE(cr.body, '') AS body,
    COALESCE(cr.cta_label, '') AS cta_label
  FROM public.ad_campaigns c
  INNER JOIN public.ad_creatives cr ON cr.campaign_id = c.id
  WHERE c.moderation_status = 'approved'
    AND c.is_active = true
    AND cr.is_active = true
    AND cr.placement = p_placement
    AND cr.platform = v_platform
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW())
  ORDER BY c.sort_priority ASC, cr.sort_priority ASC
  LIMIT 1;
END;
$$;

-- Grant permissions
REVOKE ALL ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) TO authenticated;

COMMIT;
