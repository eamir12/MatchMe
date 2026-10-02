-- Add profile_inline to default allowed placements in get_external_ad_for_placement RPC

BEGIN;

-- Drop and recreate the function with profile_inline included
DROP FUNCTION IF EXISTS public.get_external_ad_for_placement(text, text);

CREATE FUNCTION public.get_external_ad_for_placement(
  p_placement text,
  p_platform text
)
RETURNS TABLE (
  ad_unit_id uuid,
  network_id uuid,
  placement text,
  platform text,
  ad_format text,
  external_ad_unit_id text,
  is_active boolean,
  priority int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_platform text := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));
  v_user_tier text;
  v_allowed_placements jsonb;
  v_allowed_tiers jsonb;
  v_allowed_platforms jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Check if external ads are enabled
  IF NOT public.app_config_bool('ads.external.enabled', false) THEN
    RETURN;
  END IF;

  -- Get user's subscription tier
  SELECT COALESCE(NULLIF(btrim(subscription_tier), ''), 'free')
  INTO v_user_tier
  FROM public.users
  WHERE id = v_user_id;

  -- Get allowed placements, tiers, and platforms from config
  v_allowed_placements := public.app_config_jsonb('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
  v_allowed_tiers := public.app_config_jsonb('ads.external.allowed_tiers', '["free"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.external.allowed_platforms', '["android", "ios", "web"]'::jsonb);

  -- Check if placement is allowed
  IF NOT (v_allowed_placements @> to_jsonb(p_placement)) THEN
    RETURN;
  END IF;

  -- Check if user tier is allowed
  IF NOT (v_allowed_tiers @> to_jsonb(v_user_tier)) THEN
    RETURN;
  END IF;

  -- Check if platform is allowed
  IF NOT (v_allowed_platforms @> to_jsonb(v_platform)) THEN
    RETURN;
  END IF;

  -- Return ad unit with the REQUESTED platform, not the DB platform
  -- This ensures revenue events show 'android' even when falling back to web ad units
  RETURN QUERY
  SELECT
    au.id as ad_unit_id,
    au.network_id,
    au.placement,
    v_platform as platform,
    au.ad_format,
    au.ad_unit_id as external_ad_unit_id,
    au.is_active,
    au.priority
  FROM public.ad_networks an
  INNER JOIN public.ad_units au ON au.network_id = an.id
  WHERE an.is_enabled = true
    AND au.is_active = true
    AND au.placement = p_placement
    AND au.platform IN ('web', v_platform)
  ORDER BY 
    -- Prioritize exact platform match over web fallback
    CASE WHEN au.platform = v_platform THEN 0 ELSE 1 END,
    an.priority ASC, 
    au.priority ASC
  LIMIT 1;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.get_external_ad_for_placement(text, text) TO authenticated;

COMMIT;
