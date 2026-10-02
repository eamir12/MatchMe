-- Fix syntax error in record_ad_click function
-- The function was using AS $ instead of AS $$, causing it to fail

BEGIN;

DROP FUNCTION IF EXISTS public.record_ad_click(uuid, uuid, text, text, text, text) CASCADE;

CREATE FUNCTION public.record_ad_click(
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

GRANT EXECUTE ON FUNCTION public.record_ad_click(uuid, uuid, text, text, text, text) TO authenticated;

COMMIT;
