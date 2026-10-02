BEGIN;

-- Enable realtime on app_config table for immediate config updates
-- First remove if already exists to avoid errors
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE schemaname = 'public'
      AND tablename = 'app_config'
      AND pubname = 'supabase_realtime'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.app_config;
  END IF;
END $$;

-- Add the table to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.app_config;

COMMIT;
