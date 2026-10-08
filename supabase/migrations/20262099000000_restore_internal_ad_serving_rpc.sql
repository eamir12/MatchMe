-- ============================================================================
-- Restore the full-featured internal (sponsored) ad serving RPC.
--
-- The last rewrite (20260501090000) silently DROPPED several admin controls:
--   * target_tiers campaign targeting
--   * daily_impression_cap / total_impression_cap enforcement
--   * master ads.internal.allowed_placements / allowed_platforms gating
--   * platform IN ('all', platform) fallback  -> creatives with platform='all'
--     (including rows repaired by 20262069000000) became unservable everywhere
--
-- This migration restores the 20260501040000 semantics with three deliberate
-- differences:
--   1. A NULL auth.uid() no longer returns zero rows (that regression is why
--      the check was removed in 20260501080000). Anonymous context => treated
--      as 'free' tier so ads still serve.
--   2. family_safe uses the ads.internal.family_safe_only config flag (kept
--      from 20260501090000) instead of the hardcoded c.family_safe = true.
--   3. Tier comparisons are case-insensitive on both sides.
--
-- Idempotent: DROP + CREATE.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text, text, text) CASCADE;

CREATE FUNCTION public.get_sponsored_ad_for_placement(
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
  v_tier text := 'free';
  v_allowed_placements jsonb;
  v_allowed_platforms jsonb;
  v_allowed_tiers jsonb;
BEGIN
  -- Master kill switch (default OFF when the config row is missing).
  IF NOT public.app_config_bool('ads.internal.enabled', false) THEN
    RETURN;
  END IF;

  IF NOT public.app_config_bool('ads.internal.sponsored_cards_enabled', true) THEN
    RETURN;
  END IF;

  -- Resolve the viewer's tier. When auth.uid() is NULL (edge contexts that do
  -- not carry the JWT) we deliberately CONTINUE as 'free' instead of returning
  -- no rows: the 20260501080000 removal exists precisely because an early
  -- return here made the whole RPC silently serve nothing.
  IF v_user_id IS NOT NULL THEN
    SELECT COALESCE(NULLIF(lower(btrim(subscription_tier)), ''), 'free')
    INTO v_tier
    FROM public.users
    WHERE id = v_user_id;

    IF NOT FOUND THEN
      v_tier := 'free';
    END IF;
  END IF;

  -- Master placement / platform / tier gates (admin Configuration tab).
  v_allowed_placements := public.app_config_jsonb('ads.internal.allowed_placements',
    '["home_inline", "matches_inline", "chats_inline", "events_inline", "profile_inline"]'::jsonb);
  v_allowed_platforms := public.app_config_jsonb('ads.internal.allowed_platforms',
    '["android", "ios", "web", "windows", "macos", "linux"]'::jsonb);
  v_allowed_tiers := public.app_config_jsonb('ads.internal.allowed_tiers',
    '["free", "plus", "gold", "platinum"]'::jsonb);

  IF NOT (v_allowed_placements ? p_placement) THEN
    RETURN;
  END IF;

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
      cr.sort_priority AS creative_sort_priority,
      c.sort_priority AS campaign_sort_priority,
      c.id AS tiebreak_id,
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
      AND c.moderation_status = 'approved'
      AND c.starts_at <= NOW()
      AND (c.ends_at IS NULL OR c.ends_at > NOW())
      AND cr.placement = p_placement
      -- 'all' creatives serve on every platform (restored).
      AND cr.platform IN ('all', v_platform)
      -- Family-safe: hard requirement when the admin flag is on (kept from
      -- 20260501090000), no restriction when it is off.
      AND (
        NOT public.app_config_bool('ads.internal.family_safe_only', true)
        OR c.family_safe = true
      )
      -- Tier targeting: an explicit target_tiers list must contain the
      -- viewer's tier (case-insensitive); an empty list falls back to the
      -- master allowed_tiers. The tier must always also be in allowed_tiers.
      AND v_allowed_tiers ? v_tier
      AND (
        NOT EXISTS (SELECT 1 FROM unnest(COALESCE(c.target_tiers, ARRAY[]::text[])) AS tt WHERE btrim(tt) <> '')
        OR EXISTS (
          SELECT 1
          FROM unnest(COALESCE(c.target_tiers, ARRAY[]::text[])) AS tt
          WHERE lower(btrim(tt)) = v_tier
        )
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
  WHERE (eligible.daily_impression_cap IS NULL OR eligible.impressions_today < eligible.daily_impression_cap)
    AND (eligible.total_impression_cap IS NULL OR eligible.impressions_total < eligible.total_impression_cap)
  ORDER BY
    eligible.creative_sort_priority ASC,
    eligible.campaign_sort_priority ASC,
    eligible.tiebreak_id
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) TO authenticated;

COMMIT;
