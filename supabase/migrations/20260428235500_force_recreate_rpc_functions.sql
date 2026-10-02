-- Force recreate RPC functions with exact working logic
BEGIN;

-- First, test the exact query that works
DO $$
DECLARE
    test_result bigint;
BEGIN
    SELECT COUNT(*)
    INTO test_result
    FROM public.ad_revenue_events
    WHERE event_type = 'impression' 
      AND created_at >= NOW() - INTERVAL '30 days';
    
    RAISE NOTICE 'Direct query count: %', test_result;
END $$;

-- Drop existing functions completely
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_network(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_placement(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz);

-- Also drop any old versions with date parameters
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_network(date, date);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_placement(date, date);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_platform(date, date);

-- Create platform RPC with exact working logic
CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_platform(
  p_start_date timestamptz DEFAULT NOW() - INTERVAL '30 days',
  p_end_date timestamptz DEFAULT NOW()
)
RETURNS TABLE (
  platform text,
  impressions bigint,
  clicks bigint,
  revenue_usd numeric,
  ctr_percent numeric,
  cpm numeric
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(e.platform, 'unknown') as platform,
    COUNT(*)::bigint AS impressions,
    COALESCE(SUM(e.click_count), 0)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(*) > 0
      THEN (COALESCE(SUM(e.click_count), 0)::numeric / COUNT(*)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COUNT(*) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / COUNT(*)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_revenue_events e
  WHERE e.event_type = 'impression'
    AND e.created_at >= p_start_date
    AND e.created_at <= p_end_date
  GROUP BY e.platform
  ORDER BY COUNT(*) DESC;
$$;

-- Create network RPC with exact working logic  
CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_network(
  p_start_date timestamptz DEFAULT NOW() - INTERVAL '30 days',
  p_end_date timestamptz DEFAULT NOW()
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
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    n.id AS network_id,
    n.display_name AS network_name,
    COUNT(e.id)::bigint AS impressions,
    COALESCE(SUM(e.click_count), 0)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(e.id) > 0
      THEN (COALESCE(SUM(e.click_count), 0)::numeric / COUNT(e.id)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COUNT(e.id) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / COUNT(e.id)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_networks n
  LEFT JOIN public.ad_revenue_events e ON e.network_id = n.id
    AND e.event_type = 'impression'
    AND e.created_at >= p_start_date
    AND e.created_at <= p_end_date
  GROUP BY n.id, n.display_name
  ORDER BY COUNT(e.id) DESC;
$$;

-- Create placement RPC with exact working logic
CREATE OR REPLACE FUNCTION public.admin_list_external_ad_analytics_by_placement(
  p_start_date timestamptz DEFAULT NOW() - INTERVAL '30 days',
  p_end_date timestamptz DEFAULT NOW()
)
RETURNS TABLE (
  placement text,
  impressions bigint,
  clicks bigint,
  revenue_usd numeric,
  ctr_percent numeric,
  cpm numeric
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(e.placement, 'unknown') as placement,
    COUNT(*)::bigint AS impressions,
    COALESCE(SUM(e.click_count), 0)::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COUNT(*) > 0
      THEN (COALESCE(SUM(e.click_count), 0)::numeric / COUNT(*)::numeric * 100)
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COUNT(*) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / COUNT(*)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_revenue_events e
  WHERE e.event_type = 'impression'
    AND e.created_at >= p_start_date
    AND e.created_at <= p_end_date
  GROUP BY e.placement
  ORDER BY COUNT(*) DESC;
$$;

-- Verify functions were created
DO $$
BEGIN
  RAISE NOTICE 'Platform function created: %', 
    (SELECT COUNT(*) FROM pg_proc WHERE proname = 'admin_list_external_ad_analytics_by_platform');
  RAISE NOTICE 'Network function created: %', 
    (SELECT COUNT(*) FROM pg_proc WHERE proname = 'admin_list_external_ad_analytics_by_network');
  RAISE NOTICE 'Placement function created: %', 
    (SELECT COUNT(*) FROM pg_proc WHERE proname = 'admin_list_external_ad_analytics_by_placement');
END $$;

COMMIT;
