BEGIN;

-- Enable realtime on ad_impressions table for admin dashboard live analytics
-- First remove if already exists to avoid errors
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE schemaname = 'public'
      AND tablename = 'ad_impressions'
      AND pubname = 'supabase_realtime'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.ad_impressions;
  END IF;
END $$;

-- Add the table to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_impressions;

-- Enable realtime on ad_clicks table for admin dashboard live analytics
-- First remove if already exists to avoid errors
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE schemaname = 'public'
      AND tablename = 'ad_clicks'
      AND pubname = 'supabase_realtime'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.ad_clicks;
  END IF;
END $$;

-- Add the table to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_clicks;

-- Also enable realtime on ad_reports for complete real-time reporting
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE schemaname = 'public'
      AND tablename = 'ad_reports'
      AND pubname = 'supabase_realtime'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.ad_reports;
  END IF;
END $$;

-- Add the table to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_reports;

COMMIT;
