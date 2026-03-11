BEGIN;

ALTER TABLE public.admin_dashboard_tick
  ADD COLUMN IF NOT EXISTS last_table text,
  ADD COLUMN IF NOT EXISTS last_op text;

CREATE OR REPLACE FUNCTION public.touch_admin_dashboard_tick()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.admin_dashboard_tick
  SET
    updated_at = now(),
    last_table = TG_TABLE_NAME,
    last_op = TG_OP
  WHERE id = 1;

  RETURN NULL;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_chat_messages ON public.chat_messages;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_chat_messages
      AFTER INSERT ON public.chat_messages
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='matches') THEN
    DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_matches ON public.matches;
    CREATE TRIGGER trg_touch_admin_dashboard_tick_matches
      AFTER INSERT ON public.matches
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.touch_admin_dashboard_tick();
  END IF;
END $$;

COMMIT;
