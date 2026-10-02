-- Clean up orphaned click events (clicks without impressions)
-- These were created by the old record_external_ad_click function

BEGIN;

-- First, let's see what we're dealing with
DO $$
DECLARE
  v_orphaned_click_count int;
BEGIN
  SELECT COUNT(*) INTO v_orphaned_click_count
  FROM public.ad_revenue_events
  WHERE event_type = 'click'
    AND click_count = 0;  -- Standalone clicks have click_count = 0 in old system
  
  RAISE NOTICE 'Found % orphaned click events to clean up', v_orphaned_click_count;
END $$;

-- Delete orphaned click events
-- These are clicks that have:
-- 1. event_type = 'click'
-- 2. No corresponding impression (they exist as standalone rows)
-- 
-- The analytics queries are already set up to handle both click_count on impressions
-- and standalone click events, so deleting these won't break existing analytics.
-- However, since these represent invalid data (clicks without impressions),
-- removing them improves data quality.

DELETE FROM public.ad_revenue_events
WHERE event_type = 'click'
  AND click_count = 0  -- Old standalone clicks
  AND created_at < NOW() - INTERVAL '1 hour';  -- Only clean up old ones, not recent (to avoid race conditions)

-- Log the cleanup
DO $$
DECLARE
  v_deleted_count int;
BEGIN
  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  RAISE NOTICE 'Deleted % orphaned click events', v_deleted_count;
END $$;

-- Verify the cleanup
DO $$
DECLARE
  v_remaining_orphaned int;
  v_total_impressions int;
  v_total_clicks int;
BEGIN
  SELECT COUNT(*) INTO v_remaining_orphaned
  FROM public.ad_revenue_events
  WHERE event_type = 'click'
    AND click_count = 0;
  
  SELECT COUNT(*) INTO v_total_impressions
  FROM public.ad_revenue_events
  WHERE event_type = 'impression';
  
  SELECT 
    COALESCE(SUM(click_count), 0) +
    COALESCE((SELECT COUNT(*) FROM public.ad_revenue_events WHERE event_type = 'click'), 0)
  INTO v_total_clicks
  FROM public.ad_revenue_events
  WHERE event_type = 'impression';
  
  RAISE NOTICE 'After cleanup: % orphaned clicks remaining, % impressions, % clicks', 
    v_remaining_orphaned, v_total_impressions, v_total_clicks;
END $$;

COMMIT;
