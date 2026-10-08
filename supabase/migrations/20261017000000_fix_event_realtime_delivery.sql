-- Migration: Make event-import-feedback realtime deliverable
--
-- 20261013000000 tried to ALTER PUBLICATION supabase_realtime, but on
-- hosted Supabase the publication is owned by supabase_admin and the
-- postgres role used for migrations often can't alter it — the migration
-- (and with it, the admin SELECT policy) would have rolled back entirely,
-- leaving realtime silently dead for the admin Event Feedback queue.
--
-- This migration is fail-safe:
--  * re-creates the admin SELECT policy (idempotent),
--  * retries the publication adds but swallows ALL errors — if the SQL
--    role can't alter the publication, enable the tables manually in
--    Dashboard -> Database -> Replication (event_attendees, events,
--    event_import_feedback) and realtime starts delivering immediately.
BEGIN;

-- 1. Admin SELECT policy (realtime delivery is RLS-governed; also used by
--    nothing else — the queue reads via the admin_* RPCs).
DROP POLICY IF EXISTS "admin_can_view_event_import_feedback"
  ON public.event_import_feedback;

CREATE POLICY "admin_can_view_event_import_feedback"
  ON public.event_import_feedback
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.is_admin = true
    )
  );

-- 2. Publication membership, retry with full error tolerance.
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_attendees;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.events;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_import_feedback;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END;
$$;

COMMIT;
