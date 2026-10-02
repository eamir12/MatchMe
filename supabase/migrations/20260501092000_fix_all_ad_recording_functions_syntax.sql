-- Fix syntax errors in all ad recording functions
-- All functions were using AS $ instead of AS $$, causing them to fail

BEGIN;

-- Fix record_ad_impression
DROP FUNCTION IF EXISTS public.record_ad_impression(uuid, uuid, text, text, text) CASCADE;

CREATE FUNCTION public.record_ad_impression(
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

-- Fix report_ad
DROP FUNCTION IF EXISTS public.report_ad(uuid, uuid, text, text, text) CASCADE;

CREATE FUNCTION public.report_ad(
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
    p_reason,
    p_details
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_ad(uuid, uuid, text, text, text) TO authenticated;

COMMIT;
