-- Debug query to check analytics data consistency
-- Run this in Supabase SQL Editor to see why dashboard and drill-down numbers don't match

-- Check total impressions in last 30 days (what dashboard shows)
SELECT 
    'DASHBOARD TOTAL' as source,
    COUNT(*) as total_impressions,
    SUM(click_count) as total_clicks
FROM public.ad_revenue_events
WHERE event_type = 'impression'
  AND created_at >= NOW() - INTERVAL '30 days';

-- Check impressions by platform (what drill-down shows)
SELECT 
    'DRILL-DOWN BY PLATFORM' as source,
    platform,
    COUNT(*) as impressions,
    SUM(click_count) as clicks
FROM public.ad_revenue_events
WHERE event_type = 'impression'
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY platform
ORDER BY impressions DESC;

-- Check for NULL platforms
SELECT 
    'NULL PLATFORM COUNT' as source,
    COUNT(*) as impressions_with_null_platform
FROM public.ad_revenue_events
WHERE event_type = 'impression'
  AND created_at >= NOW() - INTERVAL '30 days'
  AND platform IS NULL;

-- Check impressions by network
SELECT 
    'DRILL-DOWN BY NETWORK' as source,
    n.display_name as network,
    COUNT(*) as impressions,
    SUM(e.click_count) as clicks
FROM public.ad_revenue_events e
JOIN public.ad_networks n ON n.id = e.network_id
WHERE e.event_type = 'impression'
  AND e.created_at >= NOW() - INTERVAL '30 days'
GROUP BY n.id, n.display_name
ORDER BY impressions DESC;

-- Check daily breakdown to see date range issues
SELECT 
    DATE(created_at) as date,
    platform,
    COUNT(*) as impressions
FROM public.ad_revenue_events
WHERE event_type = 'impression'
  AND created_at >= NOW() - INTERVAL '5 days'
GROUP BY DATE(created_at), platform
ORDER BY date DESC, impressions DESC;
