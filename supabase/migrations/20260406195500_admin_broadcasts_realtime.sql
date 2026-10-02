BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'admin_broadcasts'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.admin_broadcasts;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'admin_broadcast_deliveries'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.admin_broadcast_deliveries;
  END IF;
END $$;

COMMIT;
