BEGIN;

-- Enable realtime on ad_revenue_events table for admin dashboard
-- First remove if already exists to avoid errors
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE schemaname = 'public'
      AND tablename = 'ad_revenue_events'
      AND pubname = 'supabase_realtime'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.ad_revenue_events;
  END IF;
END $$;

-- Add the table to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_revenue_events;

COMMIT;
