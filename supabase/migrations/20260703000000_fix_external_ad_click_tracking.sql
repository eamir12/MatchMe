-- Fix external ad click tracking to update existing impressions instead of creating standalone click events
-- This prevents orphaned clicks (clicks without impressions)

BEGIN;

-- Replace record_external_ad_click to update existing impression instead of inserting new row
CREATE OR REPLACE FUNCTION public.record_external_ad_click(
  p_network_id uuid,
  p_ad_unit_id uuid,
  p_placement text,
  p_platform text,
  p_ad_format text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_impression_id uuid;
  v_updated_count int;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Normalize platform
  p_platform := lower(COALESCE(NULLIF(btrim(p_platform), ''), 'web'));

  -- Try to find the most recent impression for this user/placement/platform
  -- within the last 24 hours (reasonable time window for click attribution)
  SELECT id INTO v_impression_id
  FROM public.ad_revenue_events
  WHERE user_id = v_user_id
    AND network_id = p_network_id
    AND ad_unit_id = p_ad_unit_id
    AND placement = p_placement
    AND platform = p_platform
    AND event_type = 'impression'
    AND created_at >= NOW() - INTERVAL '24 hours'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_impression_id IS NOT NULL THEN
    -- Update the existing impression: increment click_count and set last_clicked_at
    UPDATE public.ad_revenue_events
    SET 
      click_count = click_count + 1,
      last_clicked_at = NOW()
    WHERE id = v_impression_id;

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    IF v_updated_count > 0 THEN
      RAISE NOTICE 'Updated impression % with click (click_count now: %)', 
        v_impression_id, 
        (SELECT click_count FROM public.ad_revenue_events WHERE id = v_impression_id);
      RETURN v_impression_id;
    END IF;
  END IF;

  -- If no recent impression found, create a standalone click event
  -- This handles edge cases like:
  -- 1. User clicks before impression tracking completes (race condition)
  -- 2. Impression was deleted/lost
  -- 3. Click attribution window expired (> 24 hours)
  
  v_impression_id := gen_random_uuid();
  
  INSERT INTO public.ad_revenue_events (
    id,
    user_id,
    network_id,
    ad_unit_id,
    placement,
    platform,
    event_type,
    ad_format,
    click_count
  )
  VALUES (
    v_impression_id,
    v_user_id,
    p_network_id,
    p_ad_unit_id,
    p_placement,
    p_platform,
    'click',
    p_ad_format,
    1  -- Set click_count to 1 for standalone clicks
  );

  RAISE WARNING 'Created standalone click event % (no matching impression found)', v_impression_id;
  RETURN v_impression_id;
END;
$$;

-- Grant permissions
REVOKE ALL ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) TO authenticated;

-- Verify function was updated
DO $$
BEGIN
  RAISE NOTICE 'External ad click tracking fixed: now updates impressions instead of creating standalone events';
END $$;

COMMIT;
