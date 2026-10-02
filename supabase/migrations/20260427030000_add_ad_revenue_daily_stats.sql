-- Create aggregated ad revenue statistics table
-- This table stores daily aggregated metrics to reduce storage and improve query performance
-- Raw events are kept in ad_revenue_events for compliance/debugging (short-term retention)

BEGIN;

-- Create daily stats table
CREATE TABLE IF NOT EXISTS public.ad_revenue_daily_stats (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  date DATE NOT NULL,
  network_id UUID NOT NULL REFERENCES public.ad_networks(id) ON DELETE CASCADE,
  ad_unit_id UUID NOT NULL REFERENCES public.ad_units(id) ON DELETE CASCADE,
  placement TEXT NOT NULL,
  platform TEXT NOT NULL,
  ad_format TEXT NOT NULL,
  
  -- Aggregated metrics
  impressions BIGINT DEFAULT 0,
  clicks BIGINT DEFAULT 0,
  conversions BIGINT DEFAULT 0,
  revenue DECIMAL(10,2) DEFAULT 0.00,
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Unique constraint to prevent duplicate aggregations
  CONSTRAINT uq_daily_stats UNIQUE (date, network_id, ad_unit_id, placement, platform, ad_format)
);

-- Create indexes for common queries
CREATE INDEX idx_daily_stats_date ON public.ad_revenue_daily_stats(date DESC);
CREATE INDEX idx_daily_stats_network ON public.ad_revenue_daily_stats(network_id);
CREATE INDEX idx_daily_stats_placement ON public.ad_revenue_daily_stats(placement);
CREATE INDEX idx_daily_stats_platform ON public.ad_revenue_daily_stats(platform);

-- Add updated_at trigger
CREATE TRIGGER update_ad_revenue_daily_stats_updated_at
  BEFORE UPDATE ON public.ad_revenue_daily_stats
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Enable Row Level Security
ALTER TABLE public.ad_revenue_daily_stats ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Allow authenticated users to read stats
CREATE POLICY "Authenticated users can read ad revenue stats"
  ON public.ad_revenue_daily_stats
  FOR SELECT
  TO authenticated
  USING (true);

-- RLS Policy: Allow service role to insert/update stats (for aggregation function)
CREATE POLICY "Service role can manage ad revenue stats"
  ON public.ad_revenue_daily_stats
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

COMMIT;
