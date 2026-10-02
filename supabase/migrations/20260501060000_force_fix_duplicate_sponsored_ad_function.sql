-- Force fix: Drop ALL versions of get_sponsored_ad_for_placement and recreate only the correct one
-- This is needed because previous migrations created multiple conflicting versions

BEGIN;

-- Drop all possible versions
DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement() CASCADE;
DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text) CASCADE;
DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text, text) CASCADE;
DROP FUNCTION IF EXISTS public.get_sponsored_ad_for_placement(text, text, text) CASCADE;

-- Recreate ONLY the correct version with explicit type casting
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

  RETURN QUERY
  SELECT
    c.id AS campaign_id,
    cr.id AS creative_id,
    cr.placement,
    cr.platform,
    c.destination_url,
    cr.image_url,
    COALESCE(c.advertiser_name, '') AS sponsor_name,
    COALESCE(cr.headline, '') AS headline,
    COALESCE(cr.body, '') AS body,
    COALESCE(cr.cta_label, '') AS cta_label
  FROM public.ad_campaigns c
  INNER JOIN public.ad_creatives cr ON cr.campaign_id = c.id
  WHERE c.moderation_status = 'approved'
    AND c.is_active = true
    AND cr.is_active = true
    AND cr.placement = p_placement
    AND cr.platform = v_platform
    AND c.starts_at <= NOW()
    AND (c.ends_at IS NULL OR c.ends_at > NOW())
  ORDER BY c.sort_priority ASC, cr.sort_priority ASC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) TO authenticated;

COMMIT;
