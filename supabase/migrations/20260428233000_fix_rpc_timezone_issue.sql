-- Fix RPC timezone issue - use timestamptz comparison instead of DATE()
BEGIN;

-- Fix RPC: Get external ad analytics by platform (timezone aware)
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
    COALESCE(e.platform, 'unknown') as platform,
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
  WHERE e.event_type = 'impression'
    AND e.created_at >= p_start_date::timestamptz
    AND e.created_at < (p_end_date + INTERVAL '1 day')::timestamptz
  GROUP BY e.platform
  ORDER BY impressions DESC NULLS LAST;
END;
$$;

-- Also fix network RPC to use timestamptz
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
    AND e.event_type = 'impression'
    AND e.created_at >= p_start_date::timestamptz
    AND e.created_at < (p_end_date + INTERVAL '1 day')::timestamptz
  GROUP BY n.id, n.display_name
  ORDER BY impressions DESC NULLS LAST;
END;
$$;

-- Also fix placement RPC
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
    COALESCE(e.placement, 'unknown') as placement,
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
  WHERE e.event_type = 'impression'
    AND e.created_at >= p_start_date::timestamptz
    AND e.created_at < (p_end_date + INTERVAL '1 day')::timestamptz
  GROUP BY e.placement
  ORDER BY impressions DESC NULLS LAST;
END;
$$;

COMMIT;
