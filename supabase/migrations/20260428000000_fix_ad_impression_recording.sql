-- Fix ad impression recording to track all impressions regardless of user tier
-- The user_can_receive_ads check should only control ad display, not analytics tracking

BEGIN;

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
  -- Only check that user is authenticated, not whether they "can receive ads"
  -- The user_can_receive_ads check should be done when deciding to SHOW the ad,
  -- not when recording that an impression occurred
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

COMMIT;
