-- Check ad serving eligibility for user: dd6d20a5-cd79-4761-8a74-751acb555b4d
-- This user is in 'free' tier - good!
-- Run each SELECT separately in Supabase SQL Editor

-- =====================================================
-- CHECK 1: Ad Network Status
-- =====================================================
SELECT 
  'Ad Network' as check_type,
  id,
  provider,
  display_name,
  is_enabled,
  CASE WHEN is_enabled THEN '✓ PASS' ELSE '✗ FAIL: Network disabled' END as status
FROM public.ad_networks
WHERE id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5';


-- =====================================================
-- CHECK 2: Active Ad Units for home_inline + web
-- =====================================================
SELECT 
  u.id,
  u.placement,
  u.platform,
  u.ad_unit_id,
  u.ad_format,
  u.is_active,
  n.is_enabled as network_enabled,
  CASE 
    WHEN u.is_active AND n.is_enabled THEN '✓ Ready to serve'
    WHEN NOT u.is_active THEN '✗ Unit inactive'
    WHEN NOT n.is_enabled THEN '✗ Network disabled'
    ELSE '?'
  END as status
FROM public.ad_units u
INNER JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement = 'home_inline'
  AND u.platform = 'web'
  AND u.network_id = 'fe6c5766-15b9-44f8-b5d7-d97b6bebf4d5';


-- =====================================================
-- CHECK 3: Config - Is external ads enabled?
-- =====================================================
SELECT 
  config_key,
  config_value::text as value,
  CASE 
    WHEN config_value::text = 'true' OR config_value::text = '"true"' 
    THEN '✓ PASS: Enabled'
    ELSE '✗ FAIL: Disabled'
  END as status
FROM public.app_config
WHERE config_key = 'ads.external.enabled';


-- =====================================================
-- CHECK 4: Config - Allowed tiers includes 'free'?
-- =====================================================
SELECT 
  config_key,
  config_value::text as value,
  CASE 
    WHEN config_value::text LIKE '%free%' 
    THEN '✓ PASS: Free tier allowed'
    ELSE '✗ FAIL: Free tier NOT allowed'
  END as status
FROM public.app_config
WHERE config_key = 'ads.external.allowed_tiers';


-- =====================================================
-- CHECK 5: Config - Placement 'home_inline' allowed?
-- =====================================================
SELECT 
  config_key,
  config_value::text as value,
  CASE 
    WHEN config_value::text LIKE '%home_inline%' 
    THEN '✓ PASS: home_inline allowed'
    ELSE '✗ FAIL: home_inline NOT allowed'
  END as status
FROM public.app_config
WHERE config_key = 'ads.external.allowed_placements';


-- =====================================================
-- CHECK 6: THE ACTUAL RPC TEST
-- =====================================================
-- This is what the app calls - should return an ad unit
SELECT 
  id,
  network_id,
  placement,
  platform,
  ad_unit_id,
  ad_format,
  is_active,
  priority
FROM public.get_external_ad_for_placement('home_inline', 'web');


-- =====================================================
-- CHECK 7: If RPC returns nothing, check why
-- =====================================================
-- Manual eligibility check
SELECT 
  'Manual Check' as check_type,
  (SELECT subscription_tier FROM public.users WHERE id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d') as user_tier,
  (SELECT public.app_config_bool('ads.external.enabled', false)) as ads_enabled,
  (SELECT public.app_config_jsonb('ads.external.allowed_tiers', '["free"]') @> '["free"]'::jsonb) as tier_allowed,
  (SELECT public.app_config_jsonb('ads.external.allowed_placements', '["home_inline"]') @> '["home_inline"]'::jsonb) as placement_allowed,
  (SELECT public.app_config_jsonb('ads.external.allowed_platforms', '["web"]') @> '["web"]'::jsonb) as platform_allowed;
