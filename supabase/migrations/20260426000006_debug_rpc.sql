-- Debug version of get_external_ad_for_placement with logging
-- This will show us exactly where the RPC is failing

CREATE OR REPLACE FUNCTION public.debug_get_external_ad_for_placement(
  p_placement text,
  p_platform text
)
RETURNS TABLE (
  debug_step text,
  debug_value text,
  ad_id uuid,
  network_id uuid,
  ad_placement text,
  platform text,
  ad_format text,
  ad_unit_id text
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
  v_ad_enabled boolean;
  v_placement_allowed boolean;
  v_tier_allowed boolean;
  v_platform_allowed boolean;
BEGIN
  -- Step 1: Check auth
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT 
      'Step 1: Auth Check'::text,
      'FAIL: auth.uid() is NULL'::text,
      null::uuid, null::uuid, null::text, null::text, null::text, null::text;
    RETURN;
  END IF;
  
  RETURN QUERY SELECT 
    'Step 1: Auth Check'::text,
    'PASS: User ID = ' || v_user_id::text,
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 2: Check if external ads are enabled
  v_ad_enabled := public.app_config_bool('ads.external.enabled', false);
  IF NOT v_ad_enabled THEN
    RETURN QUERY SELECT 
      'Step 2: Ads Enabled Check'::text,
      'FAIL: ads.external.enabled = false'::text,
      null::uuid, null::uuid, null::text, null::text, null::text, null::text;
    RETURN;
  END IF;
  
  RETURN QUERY SELECT 
    'Step 2: Ads Enabled Check'::text,
    'PASS: ads.external.enabled = true'::text,
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 3: Get user's subscription tier
  SELECT COALESCE(NULLIF(btrim(subscription_tier), ''), 'free')
  INTO v_user_tier
  FROM public.users
  WHERE id = v_user_id;
  
  RETURN QUERY SELECT 
    'Step 3: User Tier'::text,
    'User tier = ' || COALESCE(v_user_tier, 'NULL'),
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 4: Get config values
  v_allowed_placements := public.app_config_jsonb('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]'::jsonb);
  v_allowed_tiers := public.app_config_jsonb('ads.external.allowed_tiers', '["free"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.external.allowed_platforms', '["android", "ios", "web"]'::jsonb);
  
  RETURN QUERY SELECT 
    'Step 4: Config Values'::text,
    'placements=' || v_allowed_placements::text || ', tiers=' || v_allowed_tiers::text || ', platforms=' || v_allowed_platforms::text,
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 5: Check placement
  v_placement_allowed := v_allowed_placements @> to_jsonb(p_placement);
  IF NOT v_placement_allowed THEN
    RETURN QUERY SELECT 
      'Step 5: Placement Check'::text,
      'FAIL: ' || p_placement || ' not in ' || v_allowed_placements::text,
      null::uuid, null::uuid, null::text, null::text, null::text, null::text;
    RETURN;
  END IF;
  
  RETURN QUERY SELECT 
    'Step 5: Placement Check'::text,
    'PASS: ' || p_placement || ' allowed'::text,
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 6: Check tier
  v_tier_allowed := v_allowed_tiers @> to_jsonb(v_user_tier);
  IF NOT v_tier_allowed THEN
    RETURN QUERY SELECT 
      'Step 6: Tier Check'::text,
      'FAIL: tier ' || v_user_tier || ' not in ' || v_allowed_tiers::text,
      null::uuid, null::uuid, null::text, null::text, null::text, null::text;
    RETURN;
  END IF;
  
  RETURN QUERY SELECT 
    'Step 6: Tier Check'::text,
    'PASS: tier ' || v_user_tier || ' allowed'::text,
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 7: Check platform
  v_platform_allowed := v_allowed_platforms @> to_jsonb(v_platform);
  IF NOT v_platform_allowed THEN
    RETURN QUERY SELECT 
      'Step 7: Platform Check'::text,
      'FAIL: platform ' || v_platform || ' not in ' || v_allowed_platforms::text,
      null::uuid, null::uuid, null::text, null::text, null::text, null::text;
    RETURN;
  END IF;
  
  RETURN QUERY SELECT 
    'Step 7: Platform Check'::text,
    'PASS: platform ' || v_platform || ' allowed'::text,
    null::uuid, null::uuid, null::text, null::text, null::text, null::text;

  -- Step 8: Query for ad
  RETURN QUERY
  SELECT
    'Step 8: Ad Query'::text,
    'Found ad'::text,
    u.id,
    u.network_id,
    u.placement,
    u.platform,
    u.ad_format,
    u.ad_unit_id
  FROM public.ad_networks n
  INNER JOIN public.ad_units u ON u.network_id = n.id
  WHERE n.is_enabled = true
    AND u.is_active = true
    AND u.placement = p_placement
    AND u.platform IN ('web', v_platform)
  ORDER BY n.priority ASC, u.priority ASC
  LIMIT 1;
  
  -- If no rows returned from above, show that
  IF NOT FOUND THEN
    RETURN QUERY SELECT 
      'Step 8: Ad Query'::text,
      'FAIL: No matching ad units found'::text,
      null::uuid, null::uuid, null::text, null::text, null::text, null::text;
  END IF;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.debug_get_external_ad_for_placement(text, text) TO authenticated;

-- Test the debug function (run this as authenticated user)
SELECT * FROM public.debug_get_external_ad_for_placement('home_inline', 'web');
