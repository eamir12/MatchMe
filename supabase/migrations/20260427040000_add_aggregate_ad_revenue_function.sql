-- Create function to aggregate ad revenue events into daily stats
-- This function should be called periodically (e.g., via cron job) to aggregate raw events

BEGIN;

-- Function to aggregate a single day's events
CREATE OR REPLACE FUNCTION public.aggregate_ad_revenue_daily(p_date DATE DEFAULT CURRENT_DATE)
RETURNS TABLE (
  date DATE,
  network_id UUID,
  ad_unit_id UUID,
  placement TEXT,
  platform TEXT,
  ad_format TEXT,
  impressions BIGINT,
  clicks BIGINT,
  conversions BIGINT,
  revenue DECIMAL(10,2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  INSERT INTO public.ad_revenue_daily_stats (
    date,
    network_id,
    ad_unit_id,
    placement,
    platform,
    ad_format,
    impressions,
    clicks,
    conversions,
    revenue
  )
  SELECT
    p_date,
    network_id,
    ad_unit_id,
    placement,
    platform,
    ad_format,
    COUNT(*) FILTER (WHERE event_type = 'impression')::BIGINT,
    COUNT(*) FILTER (WHERE event_type = 'click')::BIGINT,
    COUNT(*) FILTER (WHERE event_type = 'conversion')::BIGINT,
    COALESCE(SUM(revenue), 0.00)
  FROM public.ad_revenue_events
  WHERE DATE(created_at) = p_date
  GROUP BY
    p_date,
    network_id,
    ad_unit_id,
    placement,
    platform,
    ad_format
  ON CONFLICT (date, network_id, ad_unit_id, placement, platform, ad_format)
  DO UPDATE SET
    impressions = EXCLUDED.impressions,
    clicks = EXCLUDED.clicks,
    conversions = EXCLUDED.conversions,
    revenue = EXCLUDED.revenue,
    updated_at = NOW()
  RETURNING
    date,
    network_id,
    ad_unit_id,
    placement,
    platform,
    ad_format,
    impressions,
    clicks,
    conversions,
    revenue;
END;
$$;

-- Function to aggregate last N days (for catch-up)
CREATE OR REPLACE FUNCTION public.aggregate_ad_revenue_last_n_days(p_days INTEGER DEFAULT 7)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_current_date DATE;
BEGIN
  v_current_date := CURRENT_DATE;
  
  FOR i IN 0..p_days-1 LOOP
    INSERT INTO public.ad_revenue_daily_stats (
      date,
      network_id,
      ad_unit_id,
      placement,
      platform,
      ad_format,
      impressions,
      clicks,
      conversions,
      revenue
    )
    SELECT
      v_current_date - i,
      network_id,
      ad_unit_id,
      placement,
      platform,
      ad_format,
      COUNT(*) FILTER (WHERE event_type = 'impression')::BIGINT,
      COUNT(*) FILTER (WHERE event_type = 'click')::BIGINT,
      COUNT(*) FILTER (WHERE event_type = 'conversion')::BIGINT,
      COALESCE(SUM(revenue), 0.00)
    FROM public.ad_revenue_events
    WHERE DATE(created_at) = v_current_date - i
    GROUP BY
      v_current_date - i,
      network_id,
      ad_unit_id,
      placement,
      platform,
      ad_format
    ON CONFLICT (date, network_id, ad_unit_id, placement, platform, ad_format)
    DO UPDATE SET
      impressions = EXCLUDED.impressions,
      clicks = EXCLUDED.clicks,
      conversions = EXCLUDED.conversions,
      revenue = EXCLUDED.revenue,
      updated_at = NOW();
    
    v_count := v_count + 1;
  END LOOP;
  
  RETURN v_count;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.aggregate_ad_revenue_daily(DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.aggregate_ad_revenue_last_n_days(INTEGER) TO authenticated;

COMMIT;
