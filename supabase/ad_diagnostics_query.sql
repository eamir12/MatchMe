-- ============================================
-- AD SYSTEM DIAGNOSTICS QUERY
-- Run this in Supabase SQL Editor to debug why ads aren't displaying
-- ============================================

-- 1. Check app_config settings for external ads
SELECT 
    'APP CONFIG' as check_type,
    config_key,
    config_value::text as value,
    CASE 
        WHEN config_value::text = 'true' THEN '✅ ENABLED'
        WHEN config_value::text = 'false' THEN '❌ DISABLED'
        ELSE config_value::text
    END as status
FROM public.app_config 
WHERE config_key LIKE 'ads.external%'
   OR config_key = 'ads.external_enabled'
ORDER BY config_key;

-- 2. Check if external ads feature flag is enabled
SELECT 
    'FEATURE FLAG' as check_type,
    'ads.external.enabled' as flag,
    public.app_config_bool('ads.external.enabled', false) as is_enabled,
    CASE 
        WHEN public.app_config_bool('ads.external.enabled', false) THEN '✅ External ads feature is ENABLED'
        ELSE '❌ External ads feature is DISABLED - set ads.external.enabled to true in app_config'
    END as status;

-- 2b. Check allowed placements specifically for profile
SELECT 
    'PLACEMENT CONFIG' as check_type,
    'ads.external.allowed_placements' as config_key,
    public.app_config_jsonb('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb)::text as current_value,
    CASE 
        WHEN (public.app_config_jsonb('ads.external.allowed_placements', '["home_inline"]'::jsonb) @> '["profile_inline"]'::jsonb) 
            THEN '✅ profile_inline IS in allowed placements'
        ELSE '❌ profile_inline NOT in allowed placements - run the fix migration'
    END as status;

-- 3. Check ad networks status
SELECT 
    'AD NETWORKS' as check_type,
    n.id::text as network_id,
    n.provider,
    n.display_name,
    n.is_enabled,
    n.priority,
    CASE 
        WHEN n.is_enabled THEN '✅ Network enabled'
        ELSE '❌ Network DISABLED - set is_enabled = true'
    END as status
FROM public.ad_networks n
ORDER BY n.priority, n.provider;

-- 4. Check ad units for all placements including profile_inline
SELECT 
    'AD UNITS' as check_type,
    u.id::text as ad_unit_id,
    n.provider as network,
    u.placement,
    u.platform,
    u.ad_format,
    u.ad_unit_id as external_ad_unit_id,
    u.is_active,
    u.priority,
    CASE 
        WHEN u.is_active AND n.is_enabled THEN '✅ Active'
        WHEN NOT u.is_active THEN '❌ Ad unit INACTIVE'
        WHEN NOT n.is_enabled THEN '❌ Network disabled'
        ELSE '❌ Unknown issue'
    END as status
FROM public.ad_units u
JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement IN ('matches_inline', 'home_inline', 'events_inline', 'chats_inline', 'profile_inline')
   OR u.placement LIKE '%inline%'
ORDER BY u.placement, u.platform, u.ad_format, u.priority;

-- 5. Check for Android platform specifically (your device is Android)
SELECT 
    'ANDROID AD UNITS' as check_type,
    u.placement,
    u.ad_format,
    u.ad_unit_id as external_ad_unit_id,
    u.is_active,
    n.is_enabled as network_enabled,
    CASE 
        WHEN u.is_active AND n.is_enabled THEN '✅ Will be used'
        ELSE '❌ Will NOT be used'
    END as status
FROM public.ad_units u
JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.platform = 'android'
ORDER BY u.placement, u.priority;

-- 6. Check what the get_external_ad_for_placement function returns for each placement
SELECT 
    'FUNCTION RESULT' as check_type,
    'matches_inline' as placement_test,
    (SELECT EXISTS (
        SELECT 1 FROM public.get_external_ad_for_placement('matches_inline', 'android')
    )) as would_return_ad,
    CASE 
        WHEN (SELECT EXISTS (SELECT 1 FROM public.get_external_ad_for_placement('matches_inline', 'android')))
        THEN '✅ Would return ad config'
        ELSE '❌ Would return NULL - check network/units'
    END as status;

SELECT 
    'FUNCTION RESULT' as check_type,
    'home_inline' as placement_test,
    (SELECT EXISTS (
        SELECT 1 FROM public.get_external_ad_for_placement('home_inline', 'android')
    )) as would_return_ad,
    CASE 
        WHEN (SELECT EXISTS (SELECT 1 FROM public.get_external_ad_for_placement('home_inline', 'android')))
        THEN '✅ Would return ad config'
        ELSE '❌ Would return NULL - check network/units'
    END as status;

SELECT 
    'FUNCTION RESULT' as check_type,
    'profile_inline' as placement_test,
    (SELECT EXISTS (
        SELECT 1 FROM public.get_external_ad_for_placement('profile_inline', 'android')
    )) as would_return_ad,
    CASE 
        WHEN (SELECT EXISTS (SELECT 1 FROM public.get_external_ad_for_placement('profile_inline', 'android')))
        THEN '✅ Would return ad config'
        ELSE '❌ Would return NULL - check network/units/placement config'
    END as status;

-- 7. Check recent ad_revenue_events to see what's being recorded
SELECT 
    'RECENT IMPRESSIONS' as check_type,
    placement,
    platform,
    ad_format,
    COUNT(*) as impression_count,
    MAX(created_at) as last_impression
FROM public.ad_revenue_events
WHERE event_type = 'impression'
  AND created_at > NOW() - INTERVAL '24 hours'
GROUP BY placement, platform, ad_format
ORDER BY last_impression DESC;

-- 8. Check if ad_unit_ids are valid Google AdMob test IDs or real IDs
SELECT 
    'AD UNIT ID VALIDATION' as check_type,
    u.placement,
    u.platform,
    u.ad_unit_id,
    CASE 
        WHEN u.ad_unit_id LIKE 'ca-app-pub-3940256099942544/%' THEN '⚠️ TEST ID (Google sample)'
        WHEN u.ad_unit_id LIKE 'ca-app-pub-%' THEN '✅ Looks like real AdMob ID'
        WHEN u.ad_unit_id = '' OR u.ad_unit_id IS NULL THEN '❌ EMPTY/NULL'
        ELSE '⚠️ Unknown format'
    END as id_type,
    CASE 
        WHEN u.ad_unit_id LIKE 'ca-app-pub-3940256099942544/%' THEN 'Test ads should work in debug builds'
        WHEN u.ad_unit_id LIKE 'ca-app-pub-%' THEN 'Real ID - verify in AdMob console'
        ELSE 'Invalid ad unit ID format'
    END as recommendation
FROM public.ad_units u
WHERE u.platform IN ('android', 'ios')
ORDER BY u.placement, u.platform;

-- 9. Check for column name mismatch bug
SELECT 
    'COLUMN MAPPING CHECK' as check_type,
    'Column names' as info,
    'SQL returns: external_ad_unit_id' as sql_column,
    'Dart uses: adUnitId (mapped from external_ad_unit_id)' as dart_mapping,
    'Status: Should work correctly' as status,
    'If ads fail: verify ad_unit_id in ad_units table is valid' as note;

-- 10. Test what the RPC actually returns
SELECT 
    'ACTUAL RPC OUTPUT' as check_type,
    x.network_id::text,
    x.ad_unit_id::text as uuid_returned_as_ad_unit_id,
    x.external_ad_unit_id as actual_admob_id,
    CASE 
        WHEN x.external_ad_unit_id IS NULL OR x.external_ad_unit_id = '' 
            THEN '❌ Missing AdMob ID'
        WHEN x.external_ad_unit_id LIKE 'ca-app-pub-%' 
            THEN '✅ Valid AdMob ID'
        ELSE '⚠️ Invalid AdMob ID format'
    END as admob_id_status
FROM public.get_external_ad_for_placement('matches_inline', 'android') x
LIMIT 1;

-- 11. Summary diagnosis
-- 11b. Check specifically for profile_inline ad units
SELECT 
    'PROFILE AD UNITS' as check_type,
    COUNT(*) as profile_ad_unit_count,
    CASE 
        WHEN COUNT(*) = 0 THEN '❌ NO ad units for profile_inline - this is why Profile screen ads are not showing'
        ELSE '✅ Found ' || COUNT(*) || ' ad unit(s) for profile_inline'
    END as status
FROM public.ad_units u
JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement = 'profile_inline'
  AND u.is_active = true
  AND n.is_enabled = true;

-- 11. Summary diagnosis
SELECT 
    'DIAGNOSIS' as check_type,
    CASE 
        WHEN NOT public.app_config_bool('ads.external.enabled', false) 
            THEN 'CRITICAL: ads.external.enabled is FALSE in app_config. External ads are disabled at the feature flag level.'
        WHEN NOT EXISTS (SELECT 1 FROM public.ad_networks WHERE is_enabled = true)
            THEN 'CRITICAL: No ad networks are enabled in ad_networks table.'
        WHEN NOT EXISTS (SELECT 1 FROM public.ad_units WHERE is_active = true AND platform = 'android')
            THEN 'CRITICAL: No active ad units for Android platform.'
        WHEN NOT EXISTS (
            SELECT 1 FROM public.ad_units u 
            JOIN public.ad_networks n ON n.id = u.network_id 
            WHERE u.placement = 'profile_inline' AND u.is_active = true AND n.is_enabled = true
        )
            THEN 'CRITICAL: No active ad units for profile_inline placement. Add ad units for profile_inline (see fix below).'
        WHEN EXISTS (
            SELECT 1 FROM public.ad_units u 
            JOIN public.ad_networks n ON n.id = u.network_id 
            WHERE u.is_active AND n.is_enabled AND u.ad_unit_id LIKE 'ca-app-pub-3940256099942544/%'
        )
            THEN 'WARNING: Using Google test ad IDs. Real ads require real AdMob IDs in ad_units table.'
        ELSE 'OK: Configuration looks correct. Check device/adblock or AdMob console for fill rate issues.'
    END as diagnosis;

-- ============================================
-- INTERNAL ADS (SPONSORED CARDS) DIAGNOSTICS
-- ============================================

-- A. Check internal ads master toggle
SELECT 
    'INTERNAL ADS' as check_type,
    'Master toggle' as check_name,
    'ads.internal.enabled' as config_key,
    public.app_config_bool('ads.internal.enabled', false) as is_enabled,
    CASE 
        WHEN public.app_config_bool('ads.internal.enabled', false) THEN '✅ Internal ads enabled'
        ELSE '❌ Internal ads DISABLED - set ads.internal.enabled to true'
    END as status;

-- B. Check sponsored cards toggle
SELECT 
    'INTERNAL ADS' as check_type,
    'Sponsored cards' as check_name,
    'ads.internal.sponsored_cards_enabled' as config_key,
    public.app_config_bool('ads.internal.sponsored_cards_enabled', true) as is_enabled,
    CASE 
        WHEN public.app_config_bool('ads.internal.sponsored_cards_enabled', true) THEN '✅ Sponsored cards enabled'
        ELSE '❌ Sponsored cards DISABLED'
    END as status;

-- C. Check internal ads allowed placements
SELECT 
    'INTERNAL ADS' as check_type,
    'Allowed placements' as check_name,
    'ads.internal.allowed_placements' as config_key,
    public.app_config_jsonb('ads.internal.allowed_placements', '["home_inline", "matches_inline"]'::jsonb)::text as current_value,
    CASE 
        WHEN (public.app_config_jsonb('ads.internal.allowed_placements', '[]'::jsonb) @> '["profile_inline"]'::jsonb) 
            THEN '✅ profile_inline IS in allowed placements'
        ELSE '❌ profile_inline NOT in internal allowed placements - add it to show Profile ads'
    END as status;

-- D. Check ad campaigns for profile_inline
SELECT 
    'INTERNAL ADS' as check_type,
    'Profile campaigns' as check_name,
    COUNT(*) as campaign_count,
    CASE 
        WHEN COUNT(*) = 0 THEN '❌ NO internal ad campaigns for profile_inline'
        ELSE '✅ Found ' || COUNT(*) || ' campaign(s) for profile_inline'
    END as status
FROM public.ad_campaigns c
JOIN public.ad_creatives cr ON cr.campaign_id = c.id
WHERE cr.placement = 'profile_inline'
  AND c.is_active = true
  AND cr.is_active = true
  AND c.moderation_status = 'approved'
  AND c.starts_at <= NOW()
  AND (c.ends_at IS NULL OR c.ends_at > NOW());

-- E. Test get_sponsored_ad_for_placement RPC for profile_inline
SELECT 
    'INTERNAL ADS' as check_type,
    'RPC test profile_inline' as check_name,
    (SELECT EXISTS (
        SELECT 1 FROM public.get_sponsored_ad_for_placement('profile_inline', 'en', 'android')
    )) as would_return_ad,
    CASE 
        WHEN (SELECT EXISTS (SELECT 1 FROM public.get_sponsored_ad_for_placement('profile_inline', 'en', 'android')))
        THEN '✅ Would return sponsored ad'
        ELSE '❌ Would return NULL - check campaigns/placements config'
    END as status;

-- F. Check tier restriction
SELECT 
    'INTERNAL ADS' as check_type,
    'Free tier only' as check_name,
    'ads.internal.free_tier_only' as config_key,
    public.app_config_bool('ads.internal.free_tier_only', true) as is_free_tier_only,
    CASE 
        WHEN public.app_config_bool('ads.internal.free_tier_only', true) 
            THEN 'ℹ️ Ads only for FREE tier users'
        ELSE 'ℹ️ Ads for all tiers'
    END as status;

-- ============================================
-- QUICK FIXES (if needed):
-- ============================================

-- To enable external ads feature:
-- UPDATE public.app_config SET config_value = 'true'::jsonb WHERE config_key = 'ads.external.enabled';

-- To enable ad network:
-- UPDATE public.ad_networks SET is_enabled = true WHERE provider = 'admob';

-- To add test ad units for Android:
/*
INSERT INTO public.ad_units (network_id, placement, platform, ad_unit_id, ad_format, is_active, priority)
SELECT 
    n.id,
    'matches_inline',
    'android',
    'ca-app-pub-3940256099942544/6300978111',
    'banner',
    true,
    100
FROM public.ad_networks n
WHERE n.provider = 'admob'
ON CONFLICT (network_id, placement, platform, ad_format) DO NOTHING;
*/

-- ============================================
-- FIX FOR PROFILE SCREEN ADS (profile_inline):
-- ============================================

-- Option 1: Copy existing ad units to profile_inline for all platforms
/*
INSERT INTO public.ad_units (network_id, placement, platform, ad_unit_id, ad_format, is_active, priority)
SELECT 
    n.id as network_id,
    'profile_inline' as placement,
    u.platform,
    u.ad_unit_id,
    u.ad_format,
    true as is_active,
    u.priority
FROM public.ad_units u
JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement = 'home_inline'
  AND u.is_active = true
  AND n.is_enabled = true
  AND NOT EXISTS (
      SELECT 1 FROM public.ad_units existing
      WHERE existing.network_id = n.id
        AND existing.placement = 'profile_inline'
        AND existing.platform = u.platform
        AND existing.ad_format = u.ad_format
  );
*/

-- Option 2: Add profile_inline ad units using your existing ad_unit_id (copy from home_inline)
-- This creates ad units for all platforms that have home_inline ads
/*
WITH existing_home_ads AS (
    SELECT DISTINCT ON (u.platform, u.ad_format)
        u.network_id,
        'profile_inline' as placement,
        u.platform,
        u.ad_unit_id,
        u.ad_format,
        true as is_active,
        u.priority
    FROM public.ad_units u
    JOIN public.ad_networks n ON n.id = u.network_id
    WHERE u.placement = 'home_inline'
      AND u.is_active = true
      AND n.is_enabled = true
)
INSERT INTO public.ad_units (network_id, placement, platform, ad_unit_id, ad_format, is_active, priority)
SELECT * FROM existing_home_ads
ON CONFLICT (network_id, placement, platform, ad_format) DO NOTHING;
*/

-- Option 3: Check what would be inserted (dry run - remove the INSERT to preview)
/*
SELECT 
    n.id as network_id,
    'profile_inline' as placement,
    u.platform,
    u.ad_unit_id,
    u.ad_format,
    true as is_active,
    u.priority
FROM public.ad_units u
JOIN public.ad_networks n ON n.id = u.network_id
WHERE u.placement = 'home_inline'
  AND u.is_active = true
  AND n.is_enabled = true
  AND NOT EXISTS (
      SELECT 1 FROM public.ad_units existing
      WHERE existing.network_id = n.id
        AND existing.placement = 'profile_inline'
        AND existing.platform = u.platform
        AND existing.ad_format = u.ad_format
  );
*/
