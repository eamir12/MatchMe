-- Fix the RPC function to use correct config key name and check placement/tier/platform restrictions
-- The RPC was checking 'ads.external_enabled' but should check 'ads.external.enabled'
-- Also needs to check user tier and allowed placements/platforms

BEGIN;

CREATE OR REPLACE FUNCTION public.get_external_ad_for_placement(
  p_placement text,
  p_platform text
)
RETURNS TABLE (
  network_id uuid,
  ad_unit_id uuid,
  placement text,
  platform text,
  ad_format text,
  ad_unit_id_external text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $
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

  -- Check if external ads are enabled using correct config key
  IF NOT public.app_config_bool('ads.external.enabled', false) THEN
    RETURN;
  END IF;

  -- Get user's subscription tier
  SELECT COALESCE(NULLIF(btrim(subscription_tier), ''), 'free')
  INTO v_user_tier
  FROM public.users
  WHERE id = v_user_id;

  -- Get allowed placements, tiers, and platforms from config
  v_allowed_placements := public.app_config_jsonb('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]'::jsonb);
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

  RETURN QUERY
  SELECT
    n.id,
    u.id,
    u.placement,
    u.platform,
    u.ad_format,
    u.ad_unit_id
  FROM public.ad_networks n
  INNER JOIN public.ad_units u ON u.network_id = n.id
  WHERE n.is_enabled = true
    AND u.is_active = true
    AND u.placement = p_placement
    AND u.platform IN ('web', v_platform)
  ORDER BY n.priority ASC, u.priority ASC
  LIMIT 1;
END;
$;

COMMIT;
