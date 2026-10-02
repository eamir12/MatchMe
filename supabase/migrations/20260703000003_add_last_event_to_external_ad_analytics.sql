-- Add last_impression_at and last_click_at to the platform analytics RPC
-- so the external ads dashboard can show "Last event" subtitles on metric cards.

DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.admin_list_external_ad_analytics_by_platform(date, date);

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
  cpm numeric,
  last_impression_at timestamptz,
  last_click_at timestamptz
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
    END::numeric AS cpm,
    MAX(CASE WHEN event_type = 'impression' THEN created_at ELSE NULL END) AS last_impression_at,
    MAX(CASE WHEN event_type = 'click' THEN created_at ELSE NULL END) AS last_click_at
  FROM public.ad_revenue_events
  WHERE event_type IN ('impression', 'click')
    AND created_at >= p_start_date
    AND created_at <= p_end_date
  GROUP BY platform
  ORDER BY COUNT(*) DESC;
$$;

REVOKE ALL ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamptz, timestamptz) TO authenticated;
