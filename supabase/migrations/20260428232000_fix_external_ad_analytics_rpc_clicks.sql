-- Fix external ad analytics RPCs to use click_count from impression events
BEGIN;

-- Fix RPC: Get external ad analytics by network
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
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::numeric / 
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

-- Fix RPC: Get external ad analytics by placement
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
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::numeric / 
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

-- Fix RPC: Get external ad analytics by platform
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
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END) > 0
      THEN (COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::numeric / 
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

COMMIT;
