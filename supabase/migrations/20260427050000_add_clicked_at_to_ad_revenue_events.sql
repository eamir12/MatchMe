BEGIN;

-- Add clicked_at column to ad_revenue_events table
ALTER TABLE public.ad_revenue_events
ADD COLUMN IF NOT EXISTS clicked_at timestamptz NULL;

-- Create index for efficient click counting
CREATE INDEX IF NOT EXISTS idx_ad_revenue_events_clicked_at
  ON public.ad_revenue_events (network_id, clicked_at)
  WHERE clicked_at IS NOT NULL;

-- Modify record_external_ad_click function to update existing impression row
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
  v_impression_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Find and update the most recent impression for this user/network/placement
  UPDATE public.ad_revenue_events
  SET clicked_at = NOW()
  WHERE id = (
    SELECT id
    FROM public.ad_revenue_events
    WHERE user_id = v_user_id
      AND network_id = p_network_id
      AND ad_unit_id = p_ad_unit_id
      AND placement = p_placement
      AND platform = lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'))
      AND event_type = 'impression'
      AND clicked_at IS NULL
    ORDER BY created_at DESC
    LIMIT 1
  )
  RETURNING id INTO v_impression_id;

  -- If no impression found to update, fall back to creating a click event
  IF v_impression_id IS NULL THEN
    INSERT INTO public.ad_revenue_events (
      id,
      user_id,
      network_id,
      ad_unit_id,
      placement,
      platform,
      event_type,
      ad_format,
      clicked_at
    )
    VALUES (
      gen_random_uuid(),
      v_user_id,
      p_network_id,
      p_ad_unit_id,
      p_placement,
      lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web')),
      'click',
      p_ad_format,
      NOW()
    )
    RETURNING id INTO v_impression_id;
  END IF;

  RETURN v_impression_id;
END;
$$;

-- Update get_ad_network_analytics to count clicks from clicked_at column
CREATE OR REPLACE FUNCTION public.get_ad_network_analytics(
  p_network_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS TABLE (
  date date,
  placement text,
  platform text,
  impressions integer,
  clicks integer,
  conversions integer,
  revenue_usd numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    DATE(e.created_at) AS date,
    e.placement,
    e.platform,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::integer AS impressions,
    COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::integer AS clicks,
    COUNT(CASE WHEN e.event_type = 'conversion' THEN 1 END)::integer AS conversions,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd
  FROM public.ad_revenue_events e
  WHERE e.network_id = p_network_id
    AND DATE(e.created_at) >= p_start_date
    AND DATE(e.created_at) <= p_end_date
  GROUP BY DATE(e.created_at), e.placement, e.platform
  ORDER BY DATE(e.created_at) DESC;
END;
$$;

-- Update analytics RPCs to use clicked_at for click counting
CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_network(
  p_start_date date DEFAULT CURRENT_DATE - INTERVAL '30 days',
  p_end_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  network_id uuid,
  network_name text,
  impressions bigint,
  clicks bigint,
  revenue_usd numeric,
  ctr_percent numeric,
  cpm numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

  RETURN QUERY
  SELECT
    n.id AS network_id,
    n.display_name AS network_name,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::bigint AS impressions,
    COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::numeric / 
            COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / 
            COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_networks n
  LEFT JOIN public.ad_revenue_events e ON e.network_id = n.id
    AND DATE(e.created_at) >= p_start_date
    AND DATE(e.created_at) <= p_end_date
  GROUP BY n.id, n.display_name
  ORDER BY revenue_usd DESC NULLS LAST;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_placement(
  p_start_date date DEFAULT CURRENT_DATE - INTERVAL '30 days',
  p_end_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  placement text,
  impressions bigint,
  clicks bigint,
  revenue_usd numeric,
  ctr_percent numeric,
  cpm numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

  RETURN QUERY
  SELECT
    e.placement,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::bigint AS impressions,
    COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::numeric / 
            COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / 
            COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_revenue_events e
  WHERE DATE(e.created_at) >= p_start_date
    AND DATE(e.created_at) <= p_end_date
  GROUP BY e.placement
  ORDER BY revenue_usd DESC NULLS LAST;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_platform(
  p_start_date date DEFAULT CURRENT_DATE - INTERVAL '30 days',
  p_end_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  platform text,
  impressions bigint,
  clicks bigint,
  revenue_usd numeric,
  ctr_percent numeric,
  cpm numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

  RETURN QUERY
  SELECT
    e.platform,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::bigint AS impressions,
    COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COUNT(CASE WHEN e.clicked_at IS NOT NULL THEN 1 END)::numeric / 
            COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / 
            COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_revenue_events e
  WHERE DATE(e.created_at) >= p_start_date
    AND DATE(e.created_at) <= p_end_date
  GROUP BY e.platform
  ORDER BY revenue_usd DESC NULLS LAST;
END;
$$;

-- Grant permissions
REVOKE ALL ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.get_ad_network_analytics(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_ad_network_analytics(uuid, date, date) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) TO authenticated;

COMMIT;
