-- Fix ad system - Recreate functions and ensure proper configuration
-- This migration fixes both internal (sponsored) and external ad systems

BEGIN;

-- ============================================
-- PART 0: Ensure ad_campaigns has target_tiers column
-- ============================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'ad_campaigns' AND column_name = 'target_tiers'
  ) THEN
    ALTER TABLE public.ad_campaigns ADD COLUMN target_tiers text[] DEFAULT ARRAY['free']::text[];
  END IF;
END $$;

-- ============================================
-- PART 1: Ensure helper functions exist
-- ============================================

-- Helper function to get JSONB config value with default
CREATE OR REPLACE FUNCTION public.app_config_jsonb(
  p_key text,
  p_default jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
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
  
  RETURN v_value;
END;
$$;

-- Helper function to get boolean config value with default
CREATE OR REPLACE FUNCTION public.app_config_bool(
  p_key text,
  p_default boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_value jsonb;
  v_result boolean;
BEGIN
  SELECT config_value::jsonb INTO v_value
  FROM public.app_config
  WHERE config_key = p_key
  LIMIT 1;
  
  IF v_value IS NULL THEN
    RETURN p_default;
  END IF;
  
  -- Try to parse as boolean
  IF jsonb_typeof(v_value) = 'boolean' THEN
    RETURN (v_value #>> '{}')::boolean;
  END IF;
  
  -- Try to parse string representation
  IF lower(trim(both '"' FROM v_value::text)) = 'true' THEN
    RETURN true;
  END IF;
  
  RETURN false;
END;
$$;

-- Helper function to check if user can receive ads
CREATE OR REPLACE FUNCTION public.user_can_receive_ads(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier text := 'free';
  v_expires_at timestamptz;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free'),
    subscription_expires_at
  INTO v_tier, v_expires_at
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Free tier users can receive ads
  IF v_tier = 'free' THEN
    RETURN true;
  END IF;

  -- Expired subscriptions can receive ads
  IF v_expires_at IS NOT NULL AND v_expires_at <= NOW() THEN
    RETURN true;
  END IF;

  -- Active paid subscribers don't see ads
  RETURN false;
END;
$$;

-- ============================================
-- PART 2: Recreate get_sponsored_ad_for_placement (Internal Ads)
-- ============================================

DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text, text, text);

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
  v_allowed_tiers jsonb;
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

  -- Load master controls with defaults including all placements, platforms and tiers
  v_allowed_placements := public.app_config_jsonb('ads.internal.allowed_placements', 
    '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.internal.allowed_platforms', 
    '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb);
  v_allowed_tiers := public.app_config_jsonb('ads.internal.allowed_tiers', 
    '["free", "plus", "gold", "platinum"]'::jsonb);

  -- Check if requested placement is allowed at master level
  IF NOT (v_allowed_placements ? p_placement) THEN
    RETURN;
  END IF;

  -- Check if requested platform is allowed at master level
  IF NOT (v_allowed_platforms ? v_platform) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT
      c.id AS campaign_id,
      cr.id AS creative_id,
      cr.placement,
      cr.platform,
      c.destination_url,
      cr.image_url,
      COALESCE(sponsor_locale.value, sponsor_en.value, c.advertiser_name) AS sponsor_name,
      COALESCE(headline_locale.value, headline_en.value) AS headline,
      COALESCE(body_locale.value, body_en.value, '') AS body,
      COALESCE(cta_locale.value, cta_en.value, '') AS cta_label,
      c.daily_impression_cap,
      c.total_impression_cap,
      c.sort_priority AS campaign_sort_priority,
      cr.sort_priority AS creative_sort_priority,
      (
        SELECT COUNT(*)
        FROM public.ad_impressions i
        WHERE i.campaign_id = c.id
          AND i.created_at >= date_trunc('day', NOW())
      ) AS impressions_today,
      (
        SELECT COUNT(*)
        FROM public.ad_impressions i
        WHERE i.campaign_id = c.id
      ) AS impressions_total
    FROM public.ad_campaigns c
    INNER JOIN public.ad_creatives cr
      ON cr.campaign_id = c.id
    LEFT JOIN public.translations headline_locale
      ON headline_locale.locale = v_locale
     AND headline_locale.key = cr.headline_key
    LEFT JOIN public.translations headline_en
      ON headline_en.locale = 'en'
     AND headline_en.key = cr.headline_key
    LEFT JOIN public.translations body_locale
      ON body_locale.locale = v_locale
     AND body_locale.key = cr.body_key
    LEFT JOIN public.translations body_en
      ON body_en.locale = 'en'
     AND body_en.key = cr.body_key
    LEFT JOIN public.translations cta_locale
      ON cta_locale.locale = v_locale
     AND cta_locale.key = cr.cta_key
    LEFT JOIN public.translations cta_en
      ON cta_en.locale = 'en'
     AND cta_en.key = cr.cta_key
    LEFT JOIN public.translations sponsor_locale
      ON sponsor_locale.locale = v_locale
     AND sponsor_locale.key = cr.sponsor_name_key
    LEFT JOIN public.translations sponsor_en
      ON sponsor_en.locale = 'en'
     AND sponsor_en.key = cr.sponsor_name_key
    WHERE c.is_active = true
      AND cr.is_active = true
      AND c.family_safe = true
      AND c.moderation_status = 'approved'
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
      AND cr.placement = p_placement
      AND cr.platform IN ('all', v_platform)
      -- Filter by target_tiers and allowed_tiers:
      -- 1. If target_tiers is explicitly set, user's tier must be in it AND in allowed_tiers
      -- 2. If target_tiers is null/empty: use allowed_tiers as the default target set
      AND (
        CASE 
          WHEN array_length(COALESCE(c.target_tiers, ARRAY[]::text[]), 1) > 0 THEN
            -- Campaign has explicit targets - check if user's tier is in both target_tiers AND allowed_tiers
            v_tier = ANY(c.target_tiers) AND v_allowed_tiers ? v_tier
          ELSE
            -- Campaign has no explicit targets - use allowed_tiers as the target set
            v_allowed_tiers ? v_tier
        END
      )
  )
  SELECT
    eligible.campaign_id,
    eligible.creative_id,
    eligible.placement,
    eligible.platform,
    eligible.destination_url,
    eligible.image_url,
    eligible.sponsor_name,
    eligible.headline,
    eligible.body,
    eligible.cta_label
  FROM eligible
  WHERE eligible.headline IS NOT NULL
    AND (eligible.daily_impression_cap IS NULL OR eligible.impressions_today < eligible.daily_impression_cap)
    AND (eligible.total_impression_cap IS NULL OR eligible.impressions_total < eligible.total_impression_cap)
  ORDER BY eligible.creative_sort_priority ASC, eligible.campaign_sort_priority ASC, eligible.campaign_id
  LIMIT 1;
END;
$$;

-- ============================================
-- PART 3: Recreate get_external_ad_for_placement (External Ads)
-- ============================================

DROP FUNCTION IF EXISTS public.get_external_ad_for_placement(text, text);

CREATE OR REPLACE FUNCTION public.get_external_ad_for_placement(
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
  SELECT COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free')
  INTO v_user_tier
  FROM public.users
  WHERE id = v_user_id;

  -- Get allowed placements, tiers, and platforms from config
  v_allowed_placements := public.app_config_jsonb('ads.external.allowed_placements', 
    '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
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

-- ============================================
-- PART 4: Recreate supporting functions for ad tracking
-- ============================================

-- Record ad impression for internal/sponsored ads
CREATE OR REPLACE FUNCTION public.record_ad_impression(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_placement text,
  p_platform text,
  p_locale text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_impressions (
    id,
    campaign_id,
    creative_id,
    user_id,
    placement,
    platform,
    locale
  )
  VALUES (
    v_id,
    p_campaign_id,
    p_creative_id,
    v_user_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en'))
  );

  RETURN v_id;
END;
$$;

-- Record ad click for internal/sponsored ads
CREATE OR REPLACE FUNCTION public.record_ad_click(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_placement text,
  p_platform text,
  p_locale text,
  p_destination_url text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_clicks (
    id,
    campaign_id,
    creative_id,
    user_id,
    placement,
    platform,
    locale,
    destination_url
  )
  VALUES (
    v_id,
    p_campaign_id,
    p_creative_id,
    v_user_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    lower(COALESCE(NULLIF(btrim(p_locale), ''), 'en')),
    p_destination_url
  );

  RETURN v_id;
END;
$$;

-- Report ad for internal/sponsored ads
CREATE OR REPLACE FUNCTION public.report_ad(
  p_campaign_id uuid,
  p_creative_id uuid,
  p_placement text,
  p_reason text,
  p_details text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_reports (
    id,
    campaign_id,
    creative_id,
    user_id,
    placement,
    reason,
    details
  )
  VALUES (
    v_id,
    p_campaign_id,
    p_creative_id,
    v_user_id,
    p_placement,
    COALESCE(NULLIF(btrim(p_reason), ''), 'user_reported'),
    NULLIF(btrim(COALESCE(p_details, '')), '')
  );

  RETURN v_id;
END;
$$;

-- Record external ad impression
CREATE OR REPLACE FUNCTION public.record_external_ad_impression(
  p_network_id uuid,
  p_ad_unit_id uuid,
  p_placement text,
  p_platform text,
  p_ad_format text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_revenue_events (
    id,
    user_id,
    network_id,
    ad_unit_id,
    placement,
    platform,
    event_type,
    ad_format
  )
  VALUES (
    v_id,
    v_user_id,
    p_network_id,
    p_ad_unit_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    'impression',
    p_ad_format
  );

  RETURN v_id;
END;
$$;

-- Record external ad click
CREATE OR REPLACE FUNCTION public.record_external_ad_click(
  p_network_id uuid,
  p_ad_unit_id uuid,
  p_placement text,
  p_platform text,
  p_ad_format text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.ad_revenue_events (
    id,
    user_id,
    network_id,
    ad_unit_id,
    placement,
    platform,
    event_type,
    ad_format
  )
  VALUES (
    v_id,
    v_user_id,
    p_network_id,
    p_ad_unit_id,
    p_placement,
    lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
    'click',
    p_ad_format
  );

  RETURN v_id;
END;
$$;

-- ============================================
-- PART 5: Ensure all required app_config entries exist
-- ============================================

-- Internal/Sponsored Ad Config
INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  ('ads.internal.enabled', 'true'::jsonb, 'boolean', 'ads', 
   'Global kill switch for internal advertising features.', false, null, null),
  ('ads.internal.sponsored_cards_enabled', 'true'::jsonb, 'boolean', 'ads', 
   'Controls whether Supabase-managed sponsored cards can be shown.', false, null, null),
  ('ads.internal.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb, 'array', 'ads', 
   'Placements where internal ads may be shown.', false, null, null),
  ('ads.internal.allowed_platforms', '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb, 'array', 'ads', 
   'Platforms where internal ads may be shown.', false, null, null),
  ('ads.internal.family_safe_only', 'true'::jsonb, 'boolean', 'ads', 
   'When enabled, only family-safe approved internal campaigns are served.', false, null, null),
  ('ads.internal.max_impressions_per_session', '0'::jsonb, 'number', 'ads', 
   'Maximum sponsored impressions allowed during a single app session.', false, 0, 20),
  ('ads.internal.min_minutes_between_impressions', '0'::jsonb, 'number', 'ads', 
   'Minimum pacing time between ad impressions for the same app session.', false, 0, 120),
  ('ads.internal.first_impression_delay_seconds', '0'::jsonb, 'number', 'ads', 
   'Minimum delay after app start before the first ad can appear.', false, 0, 1800),
  ('ads.internal.report_enabled', 'true'::jsonb, 'boolean', 'ads', 
   'Controls whether users can report a sponsored card.', false, null, null)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- External Ad Config
INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  ('ads.external.enabled', 'false'::jsonb, 'boolean', 'ads', 
   'Enable external ad networks (AdMob, Facebook, etc.)', false, null, null),
  ('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb, 'array', 'ads', 
   'Placements where external ads may be shown.', false, null, null),
  ('ads.external.allowed_tiers', '["free"]'::jsonb, 'array', 'ads', 
   'Subscription tiers that can receive external ads.', false, null, null),
  ('ads.external.allowed_platforms', '["android", "ios", "web"]'::jsonb, 'array', 'ads', 
   'Platforms where external ads may be shown.', false, null, null),
  ('ads.external.admob_enabled', 'false'::jsonb, 'boolean', 'ads', 
   'Enable Google AdMob integration', false, null, null),
  ('ads.external.mediation_enabled', 'false'::jsonb, 'boolean', 'ads', 
   'Enable ad mediation across multiple networks', false, null, null),
  ('ads.external.personalized_ads_default', 'false'::jsonb, 'boolean', 'ads', 
   'Default personalization setting for new users', false, null, null),
  ('ads.external.show_consent_form', 'true'::jsonb, 'boolean', 'ads', 
   'Show consent form to users on first app launch', false, null, null)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- ============================================
-- PART 6: Grant permissions
-- ============================================

-- Revoke existing permissions
REVOKE ALL ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_external_ad_for_placement(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_ad_impression(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_ad_click(uuid, uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.report_ad(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_external_ad_impression(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.app_config_jsonb(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.app_config_bool(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.user_can_receive_ads(uuid) FROM PUBLIC;

-- Grant to authenticated users
GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_external_ad_for_placement(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_click(uuid, uuid, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_ad(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_config_jsonb(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_config_bool(text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_receive_ads(uuid) TO authenticated;

-- Grant to service role for edge functions
GRANT EXECUTE ON FUNCTION public.app_config_jsonb(text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.app_config_bool(text, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.user_can_receive_ads(uuid) TO service_role;

COMMIT;
