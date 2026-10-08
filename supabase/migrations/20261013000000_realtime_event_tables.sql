-- Migration: Realtime updates for events and import feedback
--
-- 1. Adds the event tables to the supabase_realtime publication so
--    postgres_changes subscriptions can stream them (idempotent — tables
--    already added remotely are skipped). Delivery is still RLS-governed:
--    clients only receive rows they could SELECT.
-- 2. Gives admins a SELECT policy on event_import_feedback so the admin
--    app's Event Feedback dashboard receives realtime inserts/status
--    changes. Regular users keep their insert-only access.
BEGIN;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_attendees;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.events;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_import_feedback;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END;
$$;

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

COMMIT;
