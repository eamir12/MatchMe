-- Fix external ad analytics RPCs to properly count clicks from event_type = 'click' rows
-- The current implementation only counts clicks from click_count column on impression rows,
-- but record_external_ad_click now inserts new rows with event_type = 'click'

BEGIN;

-- Drop existing functions
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_network(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_placement(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz);

-- Create platform RPC with fixed click counting
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
    COALESCE(platform, 'unknown') as platform,
    COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::bigint AS impressions,
    (
      COALESCE(SUM(CASE WHEN event_type = 'impression' THEN click_count ELSE 0 END), 0) +
      COALESCE(SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END), 0)
    )::bigint AS clicks,
    COALESCE(SUM(revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (
        (COALESCE(SUM(CASE WHEN event_type = 'impression' THEN click_count ELSE 0 END), 0) +
         COALESCE(SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END), 0))::numeric / 
        COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 100
      )
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (COALESCE(SUM(revenue_usd), 0)::numeric / 
            COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_revenue_events
  WHERE event_type IN ('impression', 'click')
    AND created_at >= p_start_date
    AND created_at <= p_end_date
  GROUP BY platform
  ORDER BY COUNT(*) DESC;
$$;

-- Create network RPC with fixed click counting
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
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN 1 ELSE 0 END), 0)::bigint AS impressions,
    (
      COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0) +
      COALESCE(SUM(CASE WHEN e.event_type = 'click' THEN 1 ELSE 0 END), 0)
    )::bigint AS clicks,
    COALESCE(SUM(e.revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (
        (COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0) +
         COALESCE(SUM(CASE WHEN e.event_type = 'click' THEN 1 ELSE 0 END), 0))::numeric / 
        COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 100
      )
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (COALESCE(SUM(e.revenue_usd), 0)::numeric / 
            COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_networks n
  LEFT JOIN public.ad_revenue_events e ON e.network_id = n.id
    AND e.event_type IN ('impression', 'click')
    AND e.created_at >= p_start_date
    AND e.created_at <= p_end_date
  GROUP BY n.id, n.display_name
  ORDER BY COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN 1 ELSE 0 END), 0) DESC;
$$;

-- Create placement RPC with fixed click counting
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
    COALESCE(placement, 'unknown') as placement,
    COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::bigint AS impressions,
    (
      COALESCE(SUM(CASE WHEN event_type = 'impression' THEN click_count ELSE 0 END), 0) +
      COALESCE(SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END), 0)
    )::bigint AS clicks,
    COALESCE(SUM(revenue_usd), 0)::numeric AS revenue_usd,
    CASE 
      WHEN COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (
        (COALESCE(SUM(CASE WHEN event_type = 'impression' THEN click_count ELSE 0 END), 0) +
         COALESCE(SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END), 0))::numeric / 
        COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 100
      )
      ELSE 0
    END::numeric AS ctr_percent,
    CASE 
      WHEN COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0) > 0
      THEN (COALESCE(SUM(revenue_usd), 0)::numeric / 
            COALESCE(SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END), 0)::numeric * 1000)
      ELSE 0
    END::numeric AS cpm
  FROM public.ad_revenue_events
  WHERE event_type IN ('impression', 'click')
    AND created_at >= p_start_date
    AND created_at <= p_end_date
  GROUP BY placement
  ORDER BY COUNT(*) DESC;
$$;

-- Grant permissions
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz) TO authenticated;

-- Verify functions were updated
DO $$
BEGIN
  RAISE NOTICE 'External ad analytics RPCs updated to count click rows';
END $$;

COMMIT;
