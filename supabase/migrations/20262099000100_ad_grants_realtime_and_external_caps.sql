-- ============================================================================
-- Ad systems reliability fixes (external ads + permissions + realtime).
--
-- 1. Re-grant SELECT on all ad_* tables to authenticated. The 20260506200000
--    security wave revoked it and nothing ever restored it, so the ADMIN app's
--    direct reads of ad_campaigns/ad_creatives fail and silently fall back to
--    a stale offline cache. RLS (admin-only policies) still governs which rows
--    non-admin authenticated users can see, so this grant leaks nothing.
-- 2. Add ad_units / ad_networks to the supabase_realtime publication. The
--    client subscribes to Postgres changes on both tables but they were never
--    added to the publication, so admin edits never pushed an invalidation.
-- 3. Recreate get_external_ad_for_placement (last full definition:
--    20260501040000 PART 3) adding server-side enforcement of the frequency
--    caps the admin dashboard already configures:
--      ads.external.max_impressions_per_user_per_hour
--      ads.external.max_impressions_per_user_per_day
--    0 / missing = unlimited.
-- 4. Add debug_internal_ad_serving(): a read-only mirror of every gate in the
--    internal serving RPC, for diagnosing "why is my ad not showing" from the
--    SQL editor without reading app code.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Table grants (RLS still applies on top of these)
-- ----------------------------------------------------------------------------
GRANT SELECT ON public.ad_campaigns        TO authenticated;
GRANT SELECT ON public.ad_creatives        TO authenticated;
GRANT SELECT ON public.ad_impressions      TO authenticated;
GRANT SELECT ON public.ad_clicks           TO authenticated;
GRANT SELECT ON public.ad_reports          TO authenticated;
GRANT SELECT ON public.ad_networks         TO authenticated;
GRANT SELECT ON public.ad_units            TO authenticated;
GRANT SELECT ON public.ad_revenue_events   TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. Realtime publication membership (idempotent)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public' AND tablename = 'ad_units'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_units;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public' AND tablename = 'ad_networks'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_networks;
  END IF;
END $$;

-- Full old-row images so UPDATE events carry complete rows (same treatment
-- 20262069000000 gave ad_campaigns / ad_creatives).
ALTER TABLE public.ad_units    REPLICA IDENTITY FULL;
ALTER TABLE public.ad_networks REPLICA IDENTITY FULL;

-- ----------------------------------------------------------------------------
-- 3. Integer config helper (boolean/jsonb helpers already exist)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.app_config_int(
  p_key text,
  p_default integer DEFAULT 0
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_value jsonb;
BEGIN
  SELECT config_value::jsonb INTO v_value
  FROM public.app_config
  WHERE config_key = p_key
  LIMIT 1;

  IF v_value IS NULL THEN
    RETURN p_default;
  END IF;

  IF jsonb_typeof(v_value) = 'number' THEN
    RETURN (v_value #>> '{}')::integer;
  END IF;

  BEGIN
    RETURN lower(trim(both '"' FROM v_value::text))::integer;
  EXCEPTION WHEN OTHERS THEN
    RETURN p_default;
  END;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3b. External ad serving RPC — 20260501040000 PART 3 + frequency caps
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_external_ad_for_placement(text, text) CASCADE;

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
  v_max_per_hour integer;
  v_max_per_day integer;
  v_impressions_last_hour integer;
  v_impressions_today integer;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.app_config_bool('ads.external.enabled', false) THEN
    RETURN;
  END IF;

  -- Frequency caps configured in the admin External Ads dashboard. 0 (or a
  -- missing row) = unlimited. Enforced server-side so the client cannot
  -- bypass them via the cache.
  v_max_per_hour := public.app_config_int('ads.external.max_impressions_per_user_per_hour', 0);
  v_max_per_day  := public.app_config_int('ads.external.max_impressions_per_user_per_day', 0);

  IF v_max_per_hour > 0 THEN
    SELECT COUNT(*) INTO v_impressions_last_hour
    FROM public.ad_revenue_events
    WHERE user_id = v_user_id
      AND event_type = 'impression'
      AND created_at >= NOW() - INTERVAL '1 hour';

    IF v_impressions_last_hour >= v_max_per_hour THEN
      RETURN;
    END IF;
  END IF;

  IF v_max_per_day > 0 THEN
    SELECT COUNT(*) INTO v_impressions_today
    FROM public.ad_revenue_events
    WHERE user_id = v_user_id
      AND event_type = 'impression'
      AND created_at >= date_trunc('day', NOW());

    IF v_impressions_today >= v_max_per_day THEN
      RETURN;
    END IF;
  END IF;

  SELECT COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free')
  INTO v_user_tier
  FROM public.users
  WHERE id = v_user_id;

  v_allowed_placements := public.app_config_jsonb('ads.external.allowed_placements',
    '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
  v_allowed_tiers := public.app_config_jsonb('ads.external.allowed_tiers', '["free"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.external.allowed_platforms', '["android", "ios", "web"]'::jsonb);

  IF NOT (v_allowed_placements @> to_jsonb(p_placement)) THEN
    RETURN;
  END IF;

  IF NOT (v_allowed_tiers @> to_jsonb(v_user_tier)) THEN
    RETURN;
  END IF;

  IF NOT (v_allowed_platforms @> to_jsonb(v_platform)) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    au.id AS ad_unit_id,
    au.network_id,
    au.placement,
    v_platform AS platform,
    au.ad_format,
    au.ad_unit_id AS external_ad_unit_id,
    au.is_active,
    au.priority
  FROM public.ad_networks an
  INNER JOIN public.ad_units au ON au.network_id = an.id
  WHERE an.is_enabled = true
    AND au.is_active = true
    AND au.placement = p_placement
    AND au.platform IN ('web', v_platform)
  ORDER BY
    CASE WHEN au.platform = v_platform THEN 0 ELSE 1 END,
    an.priority ASC,
    au.priority ASC
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_external_ad_for_placement(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_external_ad_for_placement(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.app_config_int(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.app_config_int(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_config_int(text, integer) TO service_role;

-- ----------------------------------------------------------------------------
-- 4. Debug helper: mirror of every gate in get_sponsored_ad_for_placement.
--    Run as the signed-in user whose ad is missing, e.g.
--      SELECT * FROM debug_internal_ad_serving('home_inline', 'android');
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.debug_internal_ad_serving(
  p_placement text,
  p_platform text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_platform text := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));
  v_tier text := 'free';
  v_result jsonb;
  v_campaign_count integer;
  v_creative_count integer;
BEGIN
  SELECT COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free')
  INTO v_tier
  FROM public.users
  WHERE id = v_user_id;

  IF NOT FOUND THEN
    v_tier := 'free';
  END IF;

  SELECT COUNT(*) INTO v_campaign_count
  FROM public.ad_campaigns c
  WHERE c.moderation_status = 'approved'
    AND c.is_active = true
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW())
    AND (
      NOT public.app_config_bool('ads.internal.family_safe_only', true)
      OR c.family_safe = true
    )
    AND (
      NOT EXISTS (SELECT 1 FROM unnest(COALESCE(c.target_tiers, ARRAY[]::text[])) AS tt WHERE btrim(tt) <> '')
      OR EXISTS (
        SELECT 1 FROM unnest(COALESCE(c.target_tiers, ARRAY[]::text[])) AS tt
        WHERE lower(btrim(tt)) = v_tier
      )
    );

  SELECT COUNT(*) INTO v_creative_count
  FROM public.ad_creatives cr
  JOIN public.ad_campaigns c ON c.id = cr.campaign_id
  WHERE c.moderation_status = 'approved'
    AND c.is_active = true
    AND cr.is_active = true
    AND cr.placement = p_placement
    AND cr.platform IN ('all', v_platform)
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW())
    AND (
      NOT public.app_config_bool('ads.internal.family_safe_only', true)
      OR c.family_safe = true
    )
    AND (
      NOT EXISTS (SELECT 1 FROM unnest(COALESCE(c.target_tiers, ARRAY[]::text[])) AS tt WHERE btrim(tt) <> '')
      OR EXISTS (
        SELECT 1 FROM unnest(COALESCE(c.target_tiers, ARRAY[]::text[])) AS tt
        WHERE lower(btrim(tt)) = v_tier
      )
    );

  SELECT jsonb_build_object(
    'caller_is_admin', COALESCE((SELECT is_admin FROM public.users WHERE id = v_user_id), false),
    'viewer_tier', v_tier,
    'placement', p_placement,
    'platform', v_platform,
    'internal_enabled', public.app_config_bool('ads.internal.enabled', false),
    'sponsored_cards_enabled', public.app_config_bool('ads.internal.sponsored_cards_enabled', true),
    'family_safe_only', public.app_config_bool('ads.internal.family_safe_only', true),
    'allowed_placements', public.app_config_jsonb('ads.internal.allowed_placements', '[]'::jsonb),
    'allowed_platforms', public.app_config_jsonb('ads.internal.allowed_platforms', '[]'::jsonb),
    'allowed_tiers', public.app_config_jsonb('ads.internal.allowed_tiers', '[]'::jsonb),
    'placement_allowed_by_master', public.app_config_jsonb('ads.internal.allowed_placements', '[]'::jsonb) ? p_placement,
    'platform_allowed_by_master', public.app_config_jsonb('ads.internal.allowed_platforms', '[]'::jsonb) ? v_platform,
    'tier_allowed_by_master', public.app_config_jsonb('ads.internal.allowed_tiers', '[]'::jsonb) ? v_tier,
    'approved_active_campaigns_matching_tier', v_campaign_count,
    'servable_creatives_for_placement_platform', v_creative_count,
    'hint', CASE
      WHEN v_campaign_count = 0 THEN 'No approved+active+in-window campaigns match your tier. Check moderation_status (draft never serves) and target_tiers.'
      WHEN v_creative_count = 0 THEN 'Campaigns exist but no ACTIVE creative matches placement/platform. Creatives with platform=''all'' ARE matched. Check ad_creatives.is_active and placement spelling.'
      ELSE 'Gates pass - if the app still shows nothing, check EXECUTE grants, client caches, or client-side eligibility (session pacing/caps).'
    END
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.debug_internal_ad_serving(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.debug_internal_ad_serving(text, text) TO authenticated;

COMMIT;
