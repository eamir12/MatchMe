-- ============================================
-- AD SYSTEM DIAGNOSTIC QUERY
-- Run this in Supabase SQL Editor to identify why ads aren't displaying
-- ============================================

-- Create a diagnostic function that shows exactly what's happening
CREATE OR REPLACE FUNCTION public.debug_why_no_ad(
  p_placement text DEFAULT 'home_inline',
  p_locale text DEFAULT 'en',
  p_platform text DEFAULT 'android'
)
RETURNS TABLE (
  step_number int,
  check_name text,
  check_result text,
  details text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_locale text := lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en'));
  v_platform text := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));
  v_tier text;
  v_allowed_placements jsonb;
  v_allowed_platforms jsonb;
  v_campaign_count int;
  v_creative_count int;
  v_eligible_campaigns int;
BEGIN
  -- Step 1: Check authentication
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT 
      1,
      'Authentication'::text,
      'FAIL'::text,
      'You are not authenticated. Sign in first.'::text;
    RETURN;
  ELSE
    RETURN QUERY SELECT 
      1,
      'Authentication'::text,
      'PASS'::text,
      ('User ID: ' || v_user_id::text)::text;
  END IF;

  -- Step 2: Get user tier
  SELECT COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free')
  INTO v_tier
  FROM public.users
  WHERE id = v_user_id;
  
  IF NOT FOUND THEN
    RETURN QUERY SELECT 
      2,
      'User Tier'::text,
      'FAIL'::text,
      'User not found in users table'::text;
    RETURN;
  ELSE
    RETURN QUERY SELECT 
      2,
      'User Tier'::text,
      'PASS'::text,
      ('Tier: ' || v_tier)::text;
  END IF;

  -- Step 3: Check if internal ads are enabled
  RETURN QUERY SELECT 
    3,
    'ads.internal.enabled'::text,
    CASE WHEN public.app_config_bool('ads.internal.enabled', false) THEN 'PASS' ELSE 'FAIL' END::text,
    ('Current value: ' || public.app_config_bool('ads.internal.enabled', false)::text)::text;

  IF NOT public.app_config_bool('ads.internal.enabled', false) THEN
    RETURN QUERY SELECT 
      3,
      'FIX REQUIRED'::text,
      'ACTION'::text,
      'Run: UPDATE public.app_config SET config_value = ''true''::jsonb WHERE config_key = ''ads.internal.enabled'';'::text;
    RETURN;
  END IF;

  -- Step 4: Check sponsored cards enabled
  RETURN QUERY SELECT 
    4,
    'ads.internal.sponsored_cards_enabled'::text,
    CASE WHEN public.app_config_bool('ads.internal.sponsored_cards_enabled', true) THEN 'PASS' ELSE 'FAIL' END::text,
    ('Current value: ' || public.app_config_bool('ads.internal.sponsored_cards_enabled', true)::text)::text;

  -- Step 5: Check free tier restriction
  IF public.app_config_bool('ads.internal.free_tier_only', true) AND v_tier != 'free' THEN
    RETURN QUERY SELECT 
      5,
      'Free Tier Only Check'::text,
      'BLOCKED'::text,
      ('User tier is ' || v_tier || ' but ads.internal.free_tier_only = true. Only free users see ads.')::text;
  ELSE
    RETURN QUERY SELECT 
      5,
      'Free Tier Only Check'::text,
      'PASS'::text,
      ('free_tier_only=' || public.app_config_bool('ads.internal.free_tier_only', true)::text || ', user_tier=' || v_tier)::text;
  END IF;

  -- Step 6: Check placements config
  v_allowed_placements := public.app_config_jsonb('ads.internal.allowed_placements', '[]'::jsonb);
  RETURN QUERY SELECT 
    6,
    'Allowed Placements'::text,
    CASE WHEN (v_allowed_placements ? p_placement) THEN 'PASS' ELSE 'FAIL' END::text,
    ('Placement: ' || p_placement || ', Allowed: ' || v_allowed_placements::text)::text;

  IF NOT (v_allowed_placements ? p_placement) THEN
    RETURN QUERY SELECT 
      6,
      'FIX REQUIRED'::text,
      'ACTION'::text,
      ('Run: UPDATE public.app_config SET config_value = ''["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]''::jsonb WHERE config_key = ''ads.internal.allowed_placements'';'::text);
    RETURN;
  END IF;

  -- Step 7: Check platforms config
  v_allowed_platforms := public.app_config_jsonb('ads.internal.allowed_platforms', '[]'::jsonb);
  RETURN QUERY SELECT 
    7,
    'Allowed Platforms'::text,
    CASE WHEN (v_allowed_platforms ? v_platform) THEN 'PASS' ELSE 'FAIL' END::text,
    ('Platform: ' || v_platform || ', Allowed: ' || v_allowed_platforms::text)::text;

  IF NOT (v_allowed_platforms ? v_platform) THEN
    RETURN QUERY SELECT 
      7,
      'FIX REQUIRED'::text,
      'ACTION'::text,
      ('Run: UPDATE public.app_config SET config_value = ''["android", "ios", "web", "windows", "macos", "linux"]''::jsonb WHERE config_key = ''ads.internal.allowed_platforms'';'::text);
    RETURN;
  END IF;

  -- Step 8: Count ad campaigns
  SELECT COUNT(*) INTO v_campaign_count
  FROM public.ad_campaigns
  WHERE is_active = true
    AND moderation_status = 'approved'
    AND family_safe = true
    AND starts_at <= NOW()
    AND (ends_at IS NULL OR ends_at > NOW());

  RETURN QUERY SELECT 
    8,
    'Active Campaigns'::text,
    CASE WHEN v_campaign_count > 0 THEN 'PASS' ELSE 'FAIL' END::text,
    ('Found ' || v_campaign_count || ' active, approved campaigns')::text;

  IF v_campaign_count = 0 THEN
    RETURN QUERY SELECT 
      8,
      'FIX REQUIRED'::text,
      'ACTION'::text,
      'Create a campaign in Admin app. Set is_active=true, moderation_status=approved, family_safe=true, valid dates.'::text;
  END IF;

  -- Step 9: Count creatives for this placement
  SELECT COUNT(*) INTO v_creative_count
  FROM public.ad_creatives cr
  JOIN public.ad_campaigns c ON c.id = cr.campaign_id
  WHERE cr.placement = p_placement
    AND cr.is_active = true
    AND c.is_active = true
    AND c.moderation_status = 'approved'
    AND c.family_safe = true
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW());

  RETURN QUERY SELECT 
    9,
    'Creatives for Placement'::text,
    CASE WHEN v_creative_count > 0 THEN 'PASS' ELSE 'FAIL' END::text,
    ('Found ' || v_creative_count || ' creatives for placement=' || p_placement)::text;

  IF v_creative_count = 0 THEN
    RETURN QUERY SELECT 
      9,
      'FIX REQUIRED'::text,
      'ACTION'::text,
      ('Create a creative for placement="' || p_placement || '" in the Admin app')::text;
  END IF;

  -- Step 10: Check translations
  RETURN QUERY
  WITH creatives_with_translations AS (
    SELECT 
      cr.id as creative_id,
      cr.headline_key,
      COALESCE(t_loc.value, t_en.value) as headline_value
    FROM public.ad_creatives cr
    JOIN public.ad_campaigns c ON c.id = cr.campaign_id
    LEFT JOIN public.translations t_loc ON t_loc.key = cr.headline_key AND t_loc.locale = v_locale
    LEFT JOIN public.translations t_en ON t_en.key = cr.headline_key AND t_en.locale = 'en'
    WHERE cr.placement = p_placement
      AND cr.is_active = true
      AND c.is_active = true
      AND c.moderation_status = 'approved'
      AND c.family_safe = true
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
  )
  SELECT 
    10,
    'Translations Check'::text,
    CASE WHEN COUNT(*) > 0 AND COUNT(CASE WHEN headline_value IS NOT NULL THEN 1 END) > 0 
         THEN 'PASS' ELSE 'FAIL' END::text,
    ('Total creatives: ' || COUNT(*)::text || ', With headline translation: ' || 
     COUNT(CASE WHEN headline_value IS NOT NULL THEN 1 END)::text)::text
  FROM creatives_with_translations;

  -- Step 11: Check impression caps
  RETURN QUERY
  WITH campaign_impressions AS (
    SELECT 
      c.id as campaign_id,
      c.daily_impression_cap,
      c.total_impression_cap,
      (SELECT COUNT(*) FROM public.ad_impressions i 
       WHERE i.campaign_id = c.id AND i.created_at >= date_trunc('day', NOW())) as impressions_today,
      (SELECT COUNT(*) FROM public.ad_impressions i WHERE i.campaign_id = c.id) as impressions_total
    FROM public.ad_campaigns c
    JOIN public.ad_creatives cr ON cr.campaign_id = c.id
    WHERE cr.placement = p_placement
      AND cr.is_active = true
      AND c.is_active = true
      AND c.moderation_status = 'approved'
      AND c.family_safe = true
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
  )
  SELECT 
    11,
    'Impression Caps Check'::text,
    CASE 
      WHEN COUNT(*) = 0 THEN 'NO DATA'
      WHEN bool_or(daily_impression_cap IS NOT NULL AND impressions_today >= daily_impression_cap) THEN 'AT CAP'
      WHEN bool_or(total_impression_cap IS NOT NULL AND impressions_total >= total_impression_cap) THEN 'AT TOTAL CAP'
      ELSE 'PASS'
    END::text,
    ('Campaigns checked: ' || COUNT(*)::text)::text
  FROM campaign_impressions;

  -- Step 12: Final - what would the function return?
  RETURN QUERY
  SELECT 
    12,
    'Final Result'::text,
    CASE WHEN EXISTS (
      SELECT 1 FROM public.get_sponsored_ad_for_placement(p_placement, p_locale, p_platform)
    ) THEN 'SUCCESS - AD WOULD SHOW' ELSE 'NO AD RETURNED' END::text,
    'Call: SELECT * FROM public.get_sponsored_ad_for_placement(''' || p_placement || ''', ''' || p_locale || ''', ''' || p_platform || ''');'::text;

END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.debug_why_no_ad(text, text, text) TO authenticated;

COMMENT ON FUNCTION public.debug_why_no_ad IS 'Diagnostic function to identify why ads are not displaying. Run as authenticated user.';

-- ============================================
-- QUICK FIXES FOR COMMON ISSUES
-- ============================================

-- Fix 1: Enable internal ads if disabled
-- UPDATE public.app_config SET config_value = 'true'::jsonb WHERE config_key = 'ads.internal.enabled';

-- Fix 2: Add all placements
-- UPDATE public.app_config SET config_value = '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb WHERE config_key = 'ads.internal.allowed_placements';

-- Fix 3: Add all platforms  
-- UPDATE public.app_config SET config_value = '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb WHERE config_key = 'ads.internal.allowed_platforms';

-- Fix 4: Disable free-tier-only restriction (allow paid users to see ads too)
-- UPDATE public.app_config SET config_value = 'false'::jsonb WHERE config_key = 'ads.internal.free_tier_only';

-- ============================================
-- SAMPLE DATA INSERT (for testing)
-- Uncomment and run if you need sample data
-- ============================================

/*
-- Insert sample campaign (if none exist)
INSERT INTO public.ad_campaigns (
  internal_name, advertiser_name, destination_url, 
  moderation_status, family_safe, is_active, starts_at
) VALUES (
  'Sample Campaign', 'Test Advertiser', 'https://example.com',
  'approved', true, true, NOW()
)
ON CONFLICT DO NOTHING
RETURNING id;

-- Insert sample translations (if needed)
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'ad.sample.headline', 'Check Out This Feature!'),
  ('en', 'ad.sample.body', 'Discover amazing people near you.'),
  ('en', 'ad.sample.cta', 'Learn More'),
  ('en', 'ad.sample.sponsor', 'MatchMe Team')
ON CONFLICT (locale, key) DO NOTHING;

-- Insert sample creative (link to your campaign ID)
-- INSERT INTO public.ad_creatives (
--   campaign_id, placement, platform, headline_key, body_key, cta_key, sponsor_name_key, is_active
-- ) VALUES (
--   'YOUR-CAMPAIGN-ID-HERE', 'home_inline', 'all', 
--   'ad.sample.headline', 'ad.sample.body', 'ad.sample.cta', 'ad.sample.sponsor',
--   true
-- );
*/

-- ============================================
-- HOW TO USE
-- ============================================

-- Run this as an authenticated user in the Supabase SQL Editor:
-- SELECT * FROM public.debug_why_no_ad('home_inline', 'en', 'android');
-- 
-- Or for a different placement:
-- SELECT * FROM public.debug_why_no_ad('matches_inline', 'en', 'ios');
-- 
-- Look for FAIL or BLOCKED results to identify the issue.
