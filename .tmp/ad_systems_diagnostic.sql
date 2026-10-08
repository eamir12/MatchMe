-- ============================================================================
-- AD SYSTEMS DIAGNOSTIC (read-only) — run in Supabase SQL Editor
-- Pins down the live-DB state for both the internal (sponsored) and external
-- ad systems. Safe to run at any time; every query is SELECT-only.
-- ============================================================================

-- ============================================================================
-- 1. TABLE PRIVILEGES — did the May-6 security wave leave ad tables unreadable?
-- Expected after migration 20261007000100: all 't'. If 'f' for ad_campaigns /
-- ad_creatives, the ADMIN app cannot read campaigns and silently falls back to
-- a stale offline cache (looks like your toggles do nothing).
-- ============================================================================
SELECT
  tablename,
  has_table_privilege('authenticated', 'public.' || tablename, 'SELECT')  AS auth_can_select,
  has_table_privilege('authenticated', 'public.' || tablename, 'INSERT')  AS auth_can_insert,
  has_table_privilege('authenticated', 'public.' || tablename, 'UPDATE')  AS auth_can_update
FROM (VALUES
  ('ad_campaigns'), ('ad_creatives'), ('ad_impressions'), ('ad_clicks'),
  ('ad_reports'), ('ad_networks'), ('ad_units'), ('ad_revenue_events'), ('app_config')
) AS t(tablename);

-- ============================================================================
-- 2. EXECUTE GRANTS on the serving/recording RPCs for the end-user app.
-- Expected: all 't'. Any 'f' here = client fetch/track calls fail silently and
-- look like "no ads".
-- ============================================================================
SELECT
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'get_sponsored_ad_for_placement', 'get_external_ad_for_placement',
    'record_ad_impression', 'record_ad_click', 'report_ad',
    'record_external_ad_impression', 'record_external_ad_click',
    'app_config_bool', 'app_config_jsonb'
  )
ORDER BY p.proname, args;

-- ============================================================================
-- 3. WHICH VERSION of the serving RPCs is installed?
-- 3a. Internal RPC: shows whether the live definition still has tier targeting,
--     caps, master gating ('target_tiers' present = restored good version;
--     'platform = v_platform' WITHOUT 'all' = the regressed 20260501090000 one).
-- ============================================================================
SELECT
  pg_get_function_identity_arguments(p.oid) AS args,
  (pg_get_functiondef(p.oid) LIKE '%target_tiers%')                          AS has_tier_targeting,
  (pg_get_functiondef(p.oid) LIKE '%platform IN (''all''%')                  AS has_all_platform_fallback,
  (pg_get_functiondef(p.oid) LIKE '%daily_impression_cap%')                  AS has_impression_caps,
  (pg_get_functiondef(p.oid) LIKE '%allowed_placements%')                    AS has_master_placement_gate
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_sponsored_ad_for_placement';

-- 3b. External RPC: does the live definition enforce placements/tiers/platforms?
SELECT
  pg_get_function_identity_arguments(p.oid) AS args,
  (pg_get_functiondef(p.oid) LIKE '%allowed_placements%')                    AS has_placement_filter,
  (pg_get_functiondef(p.oid) LIKE '%allowed_tiers%')                         AS has_tier_filter,
  (pg_get_functiondef(p.oid) LIKE '%allowed_platforms%')                     AS has_platform_filter,
  (pg_get_functiondef(p.oid) LIKE '%max_impressions_per_user_per_hour%')     AS has_frequency_caps
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_external_ad_for_placement';

-- ============================================================================
-- 4. CURRENT ad CONFIGURATION (what the admin app has actually saved)
-- ============================================================================
SELECT config_key, config_value
FROM public.app_config
WHERE config_key LIKE 'ads.%'
ORDER BY config_key;

-- ============================================================================
-- 5. INTERNAL CAMPAIGNS — why "turned on but nothing shows".
-- The RPC serves only rows where: moderation_status='approved' AND is_active
-- AND starts_at<=now() AND (ends_at is null or > now()). A campaign toggled on
-- while still in 'draft' serves NOTHING. server_servable counts creatives that
-- would match a given platform ('all' + exact).
-- ============================================================================
SELECT
  c.id,
  c.internal_name,
  c.moderation_status,
  c.is_active,
  c.family_safe,
  c.starts_at,
  c.ends_at,
  c.target_tiers,
  c.daily_impression_cap,
  c.total_impression_cap,
  c.sort_priority,
  (SELECT count(*) FROM public.ad_creatives cr WHERE cr.campaign_id = c.id)                    AS total_creatives,
  (SELECT count(*) FROM public.ad_creatives cr WHERE cr.campaign_id = c.id AND cr.is_active)   AS active_creatives,
  (SELECT string_agg(DISTINCT cr.platform, ', ')
     FROM public.ad_creatives cr WHERE cr.campaign_id = c.id)                                  AS creative_platforms,
  (SELECT count(*) FROM public.ad_impressions i
    WHERE i.campaign_id = c.id AND i.created_at >= date_trunc('day', now()))                   AS impressions_today,
  (SELECT count(*) FROM public.ad_impressions i WHERE i.campaign_id = c.id)                    AS impressions_total
FROM public.ad_campaigns c
ORDER BY c.created_at DESC;

-- 5b. Creative detail: platform values per campaign ('all' rows were NEVER
-- servable since the 20260501090000 rewrite).
SELECT cr.id, cr.campaign_id, c.internal_name, cr.placement, cr.platform,
       cr.is_active, cr.sort_priority, cr.image_url IS NOT NULL AS has_image,
       cr.headline_key
FROM public.ad_creatives cr
JOIN public.ad_campaigns c ON c.id = cr.campaign_id
ORDER BY c.internal_name, cr.placement, cr.platform;

-- ============================================================================
-- 6. EXTERNAL ADS — networks and units the admin has configured
-- ============================================================================
SELECT id, provider, display_name, is_enabled, priority FROM public.ad_networks ORDER BY priority;

SELECT au.id, au.placement, au.platform, au.ad_format, au.ad_unit_id,
       au.is_active, au.priority, an.provider, an.is_enabled AS network_enabled
FROM public.ad_units au
LEFT JOIN public.ad_networks an ON an.id = au.network_id
ORDER BY au.placement, au.platform;

-- ============================================================================
-- 7. REALTIME PUBLICATION — ad_units / ad_networks must be members for the
-- client's invalidation subscriptions to ever fire.
-- Expected after migration 20261007000100: 10 tables.
-- ============================================================================
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
ORDER BY tablename;

-- ============================================================================
-- 8. RLS POLICIES on the ad tables (who can see rows directly)
-- ============================================================================
SELECT schemaname, tablename, policyname, cmd, roles,
       (qual IS NOT NULL) AS has_using,
       (with_check IS NOT NULL) AS has_with_check
FROM pg_policies
WHERE tablename IN ('ad_campaigns','ad_creatives','ad_impressions','ad_clicks',
                    'ad_reports','ad_networks','ad_units','ad_revenue_events')
ORDER BY tablename, policyname;

-- ============================================================================
-- 9. RECENT ACTIVITY — are impressions/clicks actually being recorded?
-- ============================================================================
SELECT 'internal' AS system, 'impression' AS event, count(*) AS cnt,
       max(created_at) AS last_at
FROM public.ad_impressions
UNION ALL
SELECT 'internal', 'click', count(*), max(created_at) FROM public.ad_clicks
UNION ALL
SELECT 'internal', 'report', count(*), max(created_at) FROM public.ad_reports
UNION ALL
SELECT 'external', 'impression', count(*), max(created_at)
FROM public.ad_revenue_events WHERE event_type = 'impression'
UNION ALL
SELECT 'external', 'click', count(*), max(created_at)
FROM public.ad_revenue_events WHERE event_type = 'click';

-- Last 10 internal impressions (who/where/when)
SELECT i.created_at, c.internal_name, i.placement, i.platform, i.locale, u.email
FROM public.ad_impressions i
LEFT JOIN public.ad_campaigns c ON c.id = i.campaign_id
LEFT JOIN public.users u ON u.id = i.user_id
ORDER BY i.created_at DESC
LIMIT 10;
