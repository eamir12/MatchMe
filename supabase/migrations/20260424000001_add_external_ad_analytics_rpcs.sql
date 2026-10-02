BEGIN;

-- RPC: Get external ad analytics by network
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
    COUNT(CASE WHEN e.event_type = 'click' THEN 1 END)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COUNT(CASE WHEN e.event_type = 'click' THEN 1 END)::numeric / 
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

-- RPC: Get external ad analytics by placement
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
    COUNT(CASE WHEN e.event_type = 'click' THEN 1 END)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COUNT(CASE WHEN e.event_type = 'click' THEN 1 END)::numeric / 
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

-- RPC: Get external ad analytics by platform
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
    COUNT(CASE WHEN e.event_type = 'click' THEN 1 END)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COUNT(CASE WHEN e.event_type = 'click' THEN 1 END)::numeric / 
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

-- RPC: Get external ad event details for drill-down
CREATE OR REPLACE FUNCTION public.admin_list_external_ad_event_details(
  p_filter_type text DEFAULT 'all', -- 'all', 'network', 'placement', 'platform'
  p_filter_value text DEFAULT NULL,
  p_start_date date DEFAULT CURRENT_DATE - INTERVAL '30 days',
  p_end_date date DEFAULT CURRENT_DATE,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (
  event_id uuid,
  event_type text,
  network_id uuid,
  network_name text,
  user_id uuid,
  user_name text,
  placement text,
  platform text,
  ad_format text,
  revenue_usd numeric,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_assert_is_admin();

  RETURN QUERY
  SELECT
    e.id AS event_id,
    e.event_type,
    e.network_id,
    n.display_name AS network_name,
    e.user_id,
    COALESCE(NULLIF(BTRIM(u.name), ''), e.user_id::text) AS user_name,
    e.placement,
    e.platform,
    e.ad_format,
    e.revenue_usd,
    e.created_at
  FROM public.ad_revenue_events e
  LEFT JOIN public.ad_networks n ON n.id = e.network_id
  LEFT JOIN public.users u ON u.id = e.user_id
  WHERE DATE(e.created_at) >= p_start_date
    AND DATE(e.created_at) <= p_end_date
    AND (
      p_filter_type = 'all'
      OR (p_filter_type = 'network' AND e.network_id::text = p_filter_value)
      OR (p_filter_type = 'placement' AND e.placement = p_filter_value)
      OR (p_filter_type = 'platform' AND e.platform = p_filter_value)
    )
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT GREATEST(COALESCE(p_limit, 200), 1);
END;
$$;

-- Grant execute permissions to admins
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) TO authenticated;

COMMIT;
