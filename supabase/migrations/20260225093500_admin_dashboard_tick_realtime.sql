BEGIN;

CREATE TABLE IF NOT EXISTS public.admin_dashboard_tick (
  id integer PRIMARY KEY,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.admin_dashboard_tick (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.admin_dashboard_tick ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can read admin_dashboard_tick" ON public.admin_dashboard_tick;
CREATE POLICY "Admins can read admin_dashboard_tick"
  ON public.admin_dashboard_tick
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = true
    )
  );

GRANT SELECT ON public.admin_dashboard_tick TO authenticated;

DROP FUNCTION IF EXISTS public.touch_admin_dashboard_tick();
CREATE OR REPLACE FUNCTION public.touch_admin_dashboard_tick()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.admin_dashboard_tick
  SET updated_at = now()
  WHERE id = 1;

  RETURN NULL;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='users') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_users ON public.users;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_users
      AFTER INSERT OR UPDATE OR DELETE ON public.users
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_locations') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_user_locations ON public.user_locations;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_user_locations
      AFTER INSERT OR UPDATE OR DELETE ON public.user_locations
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='matches') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_matches ON public.matches;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_matches
      AFTER INSERT OR UPDATE OR DELETE ON public.matches
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_chat_messages ON public.chat_messages;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_chat_messages
      AFTER INSERT OR UPDATE OR DELETE ON public.chat_messages
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chats') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_chats ON public.chats;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_chats
      AFTER INSERT OR UPDATE OR DELETE ON public.chats
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='profile_edit_requests') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_profile_edit_requests ON public.profile_edit_requests;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_profile_edit_requests
      AFTER INSERT OR UPDATE OR DELETE ON public.profile_edit_requests
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='admin_broadcasts') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_admin_broadcasts ON public.admin_broadcasts;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_admin_broadcasts
      AFTER INSERT OR UPDATE OR DELETE ON public.admin_broadcasts
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='notification_queue') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_notification_queue ON public.notification_queue;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_notification_queue
      AFTER INSERT OR UPDATE OR DELETE ON public.notification_queue
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'admin_dashboard_tick'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.admin_dashboard_tick;
  END IF;
END $$;

COMMIT;
