-- Test the RPC with the exact same logic and parameters
-- This will show what the RPC actually returns

-- Simulate the Flutter timestamp parameters (NOW() - 30 days, NOW())
WITH params AS (
  SELECT 
    (NOW() - INTERVAL '30 days') as p_start,
    NOW() as p_end
)
SELECT 
    'RPC SIMULATION' as test,
    COALESCE(e.platform, 'unknown') as platform,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::bigint AS impressions,
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::bigint AS clicks
FROM public.ad_revenue_events e
CROSS JOIN params p
WHERE e.event_type = 'impression'
  AND e.created_at >= p.p_start
  AND e.created_at <= p.p_end
GROUP BY e.platform

UNION ALL

-- Also show total without platform grouping
SELECT 
    'TOTAL (no GROUP BY)' as test,
    'all' as platform,
    COUNT(CASE WHEN e.event_type = 'impression' THEN 1 END)::bigint AS impressions,
    COALESCE(SUM(CASE WHEN e.event_type = 'impression' THEN e.click_count ELSE 0 END), 0)::bigint AS clicks
FROM public.ad_revenue_events e
CROSS JOIN params p
WHERE e.event_type = 'impression'
  AND e.created_at >= p.p_start
  AND e.created_at <= p.p_end;
