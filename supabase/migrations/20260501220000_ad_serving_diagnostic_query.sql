-- Ad Serving Diagnostic Query
-- Analyzes why a specific user is not seeing ads
-- Usage: Run with the user ID you're investigating
-- SELECT * FROM diagnose_ad_serving_for_user('35fe114e-eae5-49d6-9eba-8459617e7b82');

CREATE OR REPLACE FUNCTION diagnose_ad_serving_for_user(p_user_id uuid)
RETURNS TABLE (
  check_name text,
  check_status text,
  user_value text,
  required_value text,
  result text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_record RECORD;
  v_ad_config RECORD;
  v_available_campaigns INTEGER;
BEGIN
  -- ============================================
  -- USER INFORMATION
  -- ============================================
  SELECT 
    u.id,
    u.subscription_tier,
    u.subscription_expires_at,
    u.created_at,
    u.is_admin
  INTO v_user_record
  FROM public.users u
  WHERE u.id = p_user_id;

  IF v_user_record IS NULL THEN
    RETURN QUERY SELECT 
      'User Exists'::text,
      'FAIL'::text,
      'User ID: ' || p_user_id::text,
      'Valid user record'::text,
      'User not found in database - invalid or deleted user'::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT 
    'User Exists'::text,
    'PASS'::text,
    'User ID: ' || p_user_id::text,
    'Valid user record'::text,
    'User found in database'::text;

  -- ============================================
  -- AD SYSTEM CONFIGURATION CHECKS
  -- ============================================
  
  -- Check master ad enabled switch
  RETURN QUERY SELECT 
    'Ads Master Switch'::text,
    CASE WHEN public.app_config_bool('ads.internal.enabled', false) THEN 'PASS' ELSE 'FAIL' END::text,
    public.app_config_bool('ads.internal.enabled', false)::text,
    'true'::text,
    CASE WHEN public.app_config_bool('ads.internal.enabled', false)
      THEN 'ads.internal.enabled = true - Ads system is enabled'
      ELSE 'ads.internal.enabled = false - Ads system is DISABLED'
    END::text;

  -- Check sponsored cards enabled
  RETURN QUERY SELECT 
    'Sponsored Cards Enabled'::text,
    CASE WHEN public.app_config_bool('ads.internal.sponsored_cards_enabled', true) THEN 'PASS' ELSE 'FAIL' END::text,
    public.app_config_bool('ads.internal.sponsored_cards_enabled', true)::text,
    'true'::text,
    CASE WHEN public.app_config_bool('ads.internal.sponsored_cards_enabled', true)
      THEN 'ads.internal.sponsored_cards_enabled = true'
      ELSE 'ads.internal.sponsored_cards_enabled = false - Sponsored cards DISABLED'
    END::text;

  -- ============================================
  -- USER TIER ELIGIBILITY
  -- ============================================
  
  -- Determine user's effective tier
  DECLARE
    v_effective_tier TEXT := COALESCE(NULLIF(lower(btrim(v_user_record.subscription_tier)), ''), 'free');
    v_tier_eligible BOOLEAN := true;
    v_free_tier_only_config TEXT;
    v_free_tier_only_value BOOLEAN := false;  -- Default to false (show ads to all tiers)
  BEGIN
    -- Check if free_tier_only config exists
    SELECT config_value INTO v_free_tier_only_config
    FROM public.app_config
    WHERE config_key = 'ads.internal.free_tier_only';
    
    -- If config exists, use its value
    IF v_free_tier_only_config IS NOT NULL THEN
      v_free_tier_only_value := public.app_config_bool('ads.internal.free_tier_only', false);
    END IF;
    
    -- Check if user is in paid tier with active subscription
    IF v_effective_tier != 'free' AND 
       v_user_record.subscription_expires_at IS NOT NULL AND 
       v_user_record.subscription_expires_at > NOW() THEN
      v_tier_eligible := NOT v_free_tier_only_value;
    ELSE
      v_tier_eligible := true;  -- Free tier or expired subscription
    END IF;

    RETURN QUERY SELECT 
      'User Tier Eligibility'::text,
      CASE WHEN v_tier_eligible THEN 'PASS' ELSE 'FAIL' END::text,
      'Tier: ' || v_effective_tier || 
      CASE WHEN v_effective_tier = 'free' THEN ''
           WHEN v_user_record.subscription_expires_at > NOW() THEN ' (active paid)'
           ELSE ' (expired)'
      END::text,
      CASE WHEN v_free_tier_only_config IS NULL THEN 'any tier (config not set)'
           WHEN v_free_tier_only_value THEN 'free only'
           ELSE 'any tier' END::text,
      CASE 
        WHEN v_free_tier_only_config IS NULL THEN 'ads.internal.free_tier_only not set - defaulting to show ads to all tiers'
        WHEN v_tier_eligible THEN 'User is eligible for ads based on tier (' || v_effective_tier || ')'
        ELSE 'User has active paid subscription and ads.internal.free_tier_only = true - Ads blocked for paid users'
      END::text;
  END;

  -- ============================================
  -- CAMPAIGN AVAILABILITY CHECK
  -- ============================================
  
  -- Count eligible campaigns for this user
  SELECT COUNT(*)
  INTO v_available_campaigns
  FROM public.ad_campaigns c
  INNER JOIN public.ad_creatives cr ON cr.campaign_id = c.id
  WHERE c.moderation_status = 'approved'
    AND c.is_active = true
    AND cr.is_active = true
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW())
    AND (NOT public.app_config_bool('ads.internal.family_safe_only', true) OR c.family_safe = true);

  RETURN QUERY SELECT 
    'Available Campaigns'::text,
    CASE WHEN v_available_campaigns > 0 THEN 'PASS' ELSE 'FAIL' END::text,
    v_available_campaigns::text,
    '> 0'::text,
    CASE WHEN v_available_campaigns > 0 
      THEN 'Found ' || v_available_campaigns || ' eligible campaign(s)'
      ELSE 'No active, approved campaigns available for any user'
    END::text;

  -- Check campaigns targeting user's tier specifically
  DECLARE
    v_user_tier TEXT := COALESCE(NULLIF(lower(btrim(v_user_record.subscription_tier)), ''), 'free');
    v_tier_campaigns INTEGER;
  BEGIN
    SELECT COUNT(*)
    INTO v_tier_campaigns
    FROM public.ad_campaigns c
    INNER JOIN public.ad_creatives cr ON cr.campaign_id = c.id
    WHERE c.moderation_status = 'approved'
      AND c.is_active = true
      AND cr.is_active = true
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
      AND (NOT public.app_config_bool('ads.internal.family_safe_only', true) OR c.family_safe = true)
      AND (c.target_tiers IS NULL OR c.target_tiers @> ARRAY[v_user_tier]);

    RETURN QUERY SELECT 
      'Tier-Targeted Campaigns'::text,
      CASE WHEN v_tier_campaigns > 0 THEN 'INFO' ELSE 'WARN' END::text,
      v_tier_campaigns::text,
      'N/A'::text,
      CASE WHEN v_tier_campaigns > 0 
        THEN v_tier_campaigns || ' campaigns specifically target tier: ' || v_user_tier
        ELSE 'No campaigns specifically target tier ' || v_user_tier || ' (check target_tiers column)'
      END::text;
  END;

  -- ============================================
  -- PLACEMENT & PLATFORM CHECKS (requires placement/platform input)
  -- ============================================
  
  RETURN QUERY SELECT 
    'Note'::text,
    'INFO'::text,
    'To check placement/platform specific issues'::text,
    'Call function with placement/platform'::text,
    'Use: SELECT * FROM diagnose_ad_serving_for_placement(''' || p_user_id::text || ''', ''home_inline'', ''web'')'::text;

  RETURN;
END;
$$;

-- Extended function for specific placement/platform
CREATE OR REPLACE FUNCTION diagnose_ad_serving_for_placement(
  p_user_id uuid,
  p_placement text,
  p_platform text
)
RETURNS TABLE (
  check_name text,
  check_status text,
  user_value text,
  required_value text,
  result text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_record RECORD;
  v_allowed_placements jsonb;
  v_allowed_platforms jsonb;
  v_campaign_match RECORD;
BEGIN
  -- Get user info
  SELECT 
    u.id,
    COALESCE(NULLIF(lower(btrim(u.subscription_tier)), ''), 'free') as tier,
    u.subscription_expires_at
  INTO v_user_record
  FROM public.users u
  WHERE u.id = p_user_id;

  IF v_user_record IS NULL THEN
    RETURN QUERY SELECT 
      'User Exists'::text, 'FAIL'::text, p_user_id::text, 'Valid user'::text, 'User not found'::text;
    RETURN;
  END IF;

  -- Check placement allowed
  v_allowed_placements := public.app_config_jsonb('ads.internal.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]'::jsonb);
  
  RETURN QUERY SELECT 
    'Placement Allowed (' || p_placement || ')'::text,
    CASE WHEN v_allowed_placements ? p_placement THEN 'PASS' ELSE 'FAIL' END::text,
    p_placement::text,
    v_allowed_placements::text,
    CASE WHEN v_allowed_placements ? p_placement
      THEN 'Placement ' || p_placement || ' is in allowed_placements'
      ELSE 'Placement ' || p_placement || ' is NOT in ads.internal.allowed_placements: ' || v_allowed_placements::text
    END::text;

  -- Check platform allowed (using requested platform)
  v_allowed_platforms := public.app_config_jsonb('ads.internal.allowed_platforms', '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb);
  
  RETURN QUERY SELECT 
    'Platform Allowed (' || lower(p_platform) || ')'::text,
    CASE WHEN v_allowed_platforms ? lower(p_platform) THEN 'PASS' ELSE 'FAIL' END::text,
    lower(p_platform)::text,
    v_allowed_platforms::text,
    CASE WHEN v_allowed_platforms ? lower(p_platform)
      THEN 'Platform ' || lower(p_platform) || ' is in allowed_platforms'
      ELSE 'Platform ' || lower(p_platform) || ' is NOT in ads.internal.allowed_platforms: ' || v_allowed_platforms::text
    END::text;

  -- Find specific campaign that should match
  SELECT 
    c.id as campaign_id,
    c.internal_name,
    c.target_tiers,
    cr.placement,
    cr.platform,
    c.daily_impression_cap,
    c.total_impression_cap,
    (SELECT COUNT(*) FROM public.ad_impressions i WHERE i.campaign_id = c.id AND i.created_at >= date_trunc('day', NOW())) as impressions_today,
    (SELECT COUNT(*) FROM public.ad_impressions i WHERE i.campaign_id = c.id) as impressions_total
  INTO v_campaign_match
  FROM public.ad_campaigns c
  INNER JOIN public.ad_creatives cr ON cr.campaign_id = c.id
  WHERE c.moderation_status = 'approved'
    AND c.is_active = true
    AND cr.is_active = true
    AND cr.placement = p_placement
    AND cr.platform IN ('all', lower(p_platform))
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW())
    AND (NOT public.app_config_bool('ads.internal.family_safe_only', true) OR c.family_safe = true)
    AND (c.target_tiers IS NULL OR c.target_tiers @> ARRAY[v_user_record.tier])
  ORDER BY c.sort_priority ASC, cr.sort_priority ASC
  LIMIT 1;

  IF v_campaign_match IS NULL THEN
    RETURN QUERY SELECT 
      'Campaign Match for ' || p_placement || '/' || lower(p_platform)::text,
      'FAIL'::text,
      'No matching campaign'::text,
      'Active campaign with matching placement, platform, tier'::text,
      'No campaign found for placement=' || p_placement || ', platform=' || lower(p_platform) || ', tier=' || v_user_record.tier::text;
  ELSE
    -- Check impression caps
    IF v_campaign_match.daily_impression_cap IS NOT NULL AND 
       v_campaign_match.impressions_today >= v_campaign_match.daily_impression_cap THEN
      RETURN QUERY SELECT 
        'Campaign Daily Cap'::text,
        'FAIL'::text,
        v_campaign_match.impressions_today::text || ' / ' || v_campaign_match.daily_impression_cap::text,
        '< ' || v_campaign_match.daily_impression_cap::text,
        'Campaign ' || v_campaign_match.internal_name || ' has reached daily impression cap'::text;
    ELSE
      RETURN QUERY SELECT 
        'Campaign Daily Cap'::text,
        'PASS'::text,
        COALESCE(v_campaign_match.impressions_today::text || ' / ' || v_campaign_match.daily_impression_cap::text, 'no cap')::text,
        'under cap'::text,
        'Daily impressions under cap for campaign: ' || v_campaign_match.internal_name::text;
    END IF;

    IF v_campaign_match.total_impression_cap IS NOT NULL AND 
       v_campaign_match.impressions_total >= v_campaign_match.total_impression_cap THEN
      RETURN QUERY SELECT 
        'Campaign Total Cap'::text,
        'FAIL'::text,
        v_campaign_match.impressions_total::text || ' / ' || v_campaign_match.total_impression_cap::text,
        '< ' || v_campaign_match.total_impression_cap::text,
        'Campaign ' || v_campaign_match.internal_name || ' has reached total impression cap'::text;
    ELSE
      RETURN QUERY SELECT 
        'Campaign Total Cap'::text,
        'PASS'::text,
        COALESCE(v_campaign_match.impressions_total::text || ' / ' || v_campaign_match.total_impression_cap::text, 'no cap')::text,
        'under cap'::text,
        'Total impressions under cap for campaign: ' || v_campaign_match.internal_name::text;
    END IF;

    RETURN QUERY SELECT 
      'Campaign Match'::text,
      'PASS'::text,
      v_campaign_match.internal_name::text,
      p_placement || '/' || lower(p_platform)::text,
      'Found matching campaign: ' || v_campaign_match.internal_name || ' (target_tiers: ' || COALESCE(v_campaign_match.target_tiers::text, 'all') || ')'::text;
  END IF;

  RETURN;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION diagnose_ad_serving_for_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION diagnose_ad_serving_for_user(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION diagnose_ad_serving_for_placement(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION diagnose_ad_serving_for_placement(uuid, text, text) TO service_role;

COMMIT;
