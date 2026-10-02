BEGIN;

CREATE OR REPLACE FUNCTION public.admin_list_sponsored_campaign_event_details(
  p_campaign_id uuid,
  p_event_type text,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (
  event_id uuid,
  event_type text,
  campaign_id uuid,
  creative_id uuid,
  user_id uuid,
  user_name text,
  placement text,
  platform text,
  locale text,
  destination_url text,
  reason text,
  details text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_type text := lower(trim(coalesce(p_event_type, '')));
BEGIN
  PERFORM public.admin_assert_is_admin();

  IF v_event_type = 'impression' THEN
    RETURN QUERY
    SELECT
      i.id AS event_id,
      'impression'::text AS event_type,
      i.campaign_id,
      i.creative_id,
      i.user_id,
      COALESCE(NULLIF(BTRIM(u.name), ''), i.user_id::text) AS user_name,
      i.placement,
      i.platform,
      i.locale,
      NULL::text AS destination_url,
      NULL::text AS reason,
      NULL::text AS details,
      i.created_at
    FROM public.ad_impressions i
    LEFT JOIN public.users u
      ON u.id = i.user_id
    WHERE i.campaign_id = p_campaign_id
    ORDER BY i.created_at DESC, i.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 200), 1);
    RETURN;
  END IF;

  IF v_event_type = 'click' THEN
    RETURN QUERY
    SELECT
      c.id AS event_id,
      'click'::text AS event_type,
      c.campaign_id,
      c.creative_id,
      c.user_id,
      COALESCE(NULLIF(BTRIM(u.name), ''), c.user_id::text) AS user_name,
      c.placement,
      c.platform,
      c.locale,
      c.destination_url,
      NULL::text AS reason,
      NULL::text AS details,
      c.created_at
    FROM public.ad_clicks c
    LEFT JOIN public.users u
      ON u.id = c.user_id
    WHERE c.campaign_id = p_campaign_id
    ORDER BY c.created_at DESC, c.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 200), 1);
    RETURN;
  END IF;

  RAISE EXCEPTION 'Unsupported sponsored ad event type: %', p_event_type
    USING ERRCODE = '22023';
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_sponsored_campaign_event_details(uuid, text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_event_details(uuid, text, integer) TO authenticated;

COMMIT;
