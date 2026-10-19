-- Migration: Ensure the notification inbox table is realtime-deliverable.
--
-- The in-app notification inbox (lib/providers/notification_inbox_provider.dart)
-- updates its list and unread badge from postgres_changes INSERTs on
-- public.user_notifications. Realtime only delivers for tables in the
-- supabase_realtime publication.
--
-- 20261001000000 (create_user_notification_inbox) tried to ADD TABLE inside a
-- guarded DO block, but on hosted Supabase the publication is owned by
-- supabase_admin and the postgres role used for migrations often can't alter
-- it (the same failure documented in
-- 20261017000000_fix_event_realtime_delivery.sql). When that ALTER fails there
-- are two outcomes: the whole migration rolls back (table missing — loud), or
-- the table exists but was never published (realtime silently dead — the loud
-- symptom being an inbox that only updates on manual refresh).
--
-- This migration is fail-safe:
--  * retries the publication add but swallows ALL errors (including
--    "already member of publication", making it a no-op there),
--  * if the SQL role still can't alter the publication, enable the table
--    manually in Dashboard -> Database -> Replication (public.user_notifications)
--    and realtime starts delivering immediately.
BEGIN;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_notifications;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END;
$$;

COMMIT;
