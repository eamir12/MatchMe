-- Debug: Find where the missing 30 impressions are

-- 1. Total impressions (should be 80)
SELECT 'TOTAL' as category, COUNT(*) as impressions, SUM(click_count) as clicks
FROM public.ad_revenue_events
WHERE event_type = 'impression' AND created_at >= NOW() - INTERVAL '30 days';

-- 2. By platform including NULL
SELECT 'Platform: ' || COALESCE(platform, 'NULL') as category, COUNT(*) as impressions, SUM(click_count) as clicks
FROM public.ad_revenue_events
WHERE event_type = 'impression' AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY platform;

-- 3. By network
SELECT 'Network: ' || COALESCE(n.display_name, 'NULL') as category, COUNT(*) as impressions, SUM(e.click_count) as clicks
FROM public.ad_revenue_events e
LEFT JOIN public.ad_networks n ON n.id = e.network_id
WHERE e.event_type = 'impression' AND e.created_at >= NOW() - INTERVAL '30 days'
GROUP BY n.display_name;

-- 4. Recent raw events to see platform values
SELECT 'Raw: ' || LEFT(id::text, 8) || ' - ' || COALESCE(platform, 'NULL') || ' - ' || created_at::text as category, 
       1 as impressions, click_count as clicks
FROM public.ad_revenue_events
WHERE event_type = 'impression' 
  AND created_at >= '2026-04-29'::date
ORDER BY created_at DESC
LIMIT 10;
