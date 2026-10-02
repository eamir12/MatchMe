-- Diagnostic queries for external ads - Run each one separately in Supabase SQL Editor
-- Run these as an authenticated user (the same user logged into the app)

-- =====================================================
-- QUERY 1: Check current user and their tier
-- =====================================================
SELECT 
  auth.uid() as your_user_id,
  (SELECT subscription_tier FROM public.users WHERE id = auth.uid()) as your_tier,
  (SELECT email FROM public.users WHERE id = auth.uid()) as your_email,
  CASE 
    WHEN (SELECT subscription_tier FROM public.users WHERE id = auth.uid()) = 'free' 
    THEN '✓ PASS: You are in free tier'
    ELSE '✗ FAIL: You are NOT in free tier - ads will not show!'
  END as tier_check;


-- =====================================================
-- QUERY 2: Check external ads config
-- =====================================================
SELECT 
  config_key,
  config_value::text as value,
  config_type,
  CASE 
    WHEN config_key = 'ads.external.enabled' AND (config_value = 'true' OR config_value = '"true"' OR config_value::text = 'true') 
      THEN '✓ PASS: External ads enabled'
    WHEN config_key = 'ads.external.enabled' 
      THEN '✗ FAIL: External ads DISABLED'
    WHEN config_key = 'ads.external.allowed_tiers' AND config_value::text LIKE '%free%' 
      THEN '✓ PASS: Free tier allowed'
    WHEN config_key = 'ads.external.allowed_tiers' 
      THEN '✗ FAIL: Free tier NOT in allowed tiers'
    WHEN config_key = 'ads.external.allowed_placements' AND config_value::text LIKE '%home_inline%' 
      THEN '✓ PASS: home_inline placement allowed'
    WHEN config_key = 'ads.external.allowed_platforms' AND config_value::text LIKE '%web%' 
      THEN '✓ PASS: web platform allowed'
    ELSE 'INFO'
  END as status
FROM public.app_config
WHERE config_key LIKE 'ads.external.%'
ORDER BY config_key;


-- =====================================================
-- QUERY 3: Check if ad network is enabled
-- =====================================================
SELECT 
  id,
  provider,
  display_name,
  is_enabled,
  priority,
  CASE 
    WHEN is_enabled THEN '✓ PASS: Network is enabled'
    ELSE '✗ FAIL: Network is DISABLED!'
  END as network_status
FROM public.ad_networks
WHERE id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5';


-- =====================================================
-- QUERY 4: Check ALL active ad units
-- =====================================================
SELECT 
  u.id,
  u.placement,
  u.platform,
  u.ad_unit_id,
  u.ad_format,
  u.is_active,
  u.priority,
  n.provider,
  n.is_enabled as network_enabled,
  CASE 
    WHEN u.is_active AND n.is_enabled THEN '✓ READY'
    WHEN NOT u.is_active THEN '✗ Ad unit inactive'
    WHEN NOT n.is_enabled THEN '✗ Network disabled'
    ELSE '?'
  END as status
FROM public.ad_units u
INNER JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.network_id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5'
ORDER BY u.placement, u.platform;


-- =====================================================
-- QUERY 5: Test the actual RPC call (what the app calls)
-- =====================================================
-- This simulates what happens when the app requests an ad
SELECT 
  'home_inline' as requested_placement,
  'web' as requested_platform,
  COALESCE(
    (SELECT jsonb_build_object(
      'ad_id', id,
      'network_id', network_id,
      'placement', placement,
      'platform', platform,
      'ad_unit_id', ad_unit_id,
      'ad_format', ad_format
    ) FROM public.get_external_ad_for_placement('home_inline', 'web') LIMIT 1),
    'null'::jsonb
  ) as rpc_result,
  CASE 
    WHEN EXISTS (SELECT 1 FROM public.get_external_ad_for_placement('home_inline', 'web')) 
    THEN '✓ PASS: RPC returned an ad'
    ELSE '✗ FAIL: RPC returned NULL - check steps above'
  END as rpc_status;


-- =====================================================
-- QUERY 6: Manual test of eligibility logic
-- =====================================================
-- This shows step-by-step what the RPC checks
SELECT 
  'Step 1: External ads enabled?' as step,
  public.app_config_bool('ads.external.enabled', false) as check_result;

SELECT 
  'Step 2: Is user authenticated?' as step,
  (auth.uid() IS NOT NULL) as check_result,
  auth.uid() as user_id;

SELECT 
  'Step 3: User tier check' as step,
  (SELECT subscription_tier FROM public.users WHERE id = auth.uid()) as user_tier,
  (SELECT public.app_config_jsonb('ads.external.allowed_tiers', '["free"]')) as allowed_tiers,
  (SELECT 
    (SELECT public.app_config_jsonb('ads.external.allowed_tiers', '["free"]')) 
    @> to_jsonb((SELECT subscription_tier FROM public.users WHERE id = auth.uid()))
  ) as tier_allowed;

SELECT 
  'Step 4: Placement check' as step,
  'home_inline' as requested_placement,
  (SELECT public.app_config_jsonb('ads.external.allowed_placements', '["home_inline"]')) as allowed_placements,
  (SELECT 
    (SELECT public.app_config_jsonb('ads.external.allowed_placements', '["home_inline"]')) 
    @> to_jsonb('home_inline'::text)
  ) as placement_allowed;

SELECT 
  'Step 5: Platform check' as step,
  'web' as requested_platform,
  (SELECT public.app_config_jsonb('ads.external.allowed_platforms', '["web"]')) as allowed_platforms,
  (SELECT 
    (SELECT public.app_config_jsonb('ads.external.allowed_platforms', '["web"]')) 
    @> to_jsonb('web'::text)
  ) as platform_allowed;
