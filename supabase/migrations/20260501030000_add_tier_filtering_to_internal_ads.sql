-- Add tier filtering to internal ad system based on campaign target_tiers

BEGIN;

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
  v_tier text;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.app_config_bool('ads.internal.enabled', false) THEN
    RETURN;
  END IF;

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

  -- Check free tier only restriction
  IF public.app_config_bool('ads.internal.free_tier_only', true) AND v_tier != 'free' THEN
    -- If free_tier_only is true, only free users can see ads
    RETURN;
  END IF;

  -- Load master controls
  v_allowed_placements := public.app_config_jsonb('ads.internal.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.internal.allowed_platforms', '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb);

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
      AND (NOT public.app_config_bool('ads.internal.family_safe_only', true) OR c.family_safe = true)
      AND c.moderation_status = 'approved'
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
      AND cr.placement = p_placement
      AND cr.platform IN ('all', v_platform)
      -- Filter by target_tiers: if null/empty, show to all; else check if user's tier is included
      AND (c.metadata->'target_tiers' IS NULL
           OR jsonb_array_length(COALESCE(c.metadata->'target_tiers', '[]'::jsonb)) = 0
           OR (COALESCE(c.metadata->'target_tiers', '[]'::jsonb))::jsonb ? v_tier)
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

COMMIT;