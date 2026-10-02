-- Test the platform RPC directly with debug output
-- This mimics exactly what the dashboard sends

-- Test with the same timestamps the Flutter app sends
SELECT 
    'TEST' as source,
    COALESCE(e.platform, 'unknown') as platform,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::bigint AS impressions,
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::bigint AS clicks
FROM public.ad_revenue_events e
WHERE e.event_type = 'impression'
  AND e.created_at >= (NOW() - INTERVAL '30 days')
  AND e.created_at <= NOW()
GROUP BY e.platform
ORDER BY impressions DESC;
