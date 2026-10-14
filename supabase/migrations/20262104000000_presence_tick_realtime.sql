-- Migration: presence_tick — instant online-counter refresh on login/logout
-- Date: 2026-10-13
-- WHY: The home screen online counter, the online world-map country markers
--      and the admin dashboard LIVE cards all depend on Supabase Realtime
--      postgres_changes events from user_activity / user_session. Those
--      subscriptions only deliver rows the subscriber is allowed to SELECT
--      under RLS, so when a client cannot read other users' presence rows
--      the logon/logoff events never arrive and the counters freeze until a
--      fallback timer fires (up to 5 minutes on Home, 30s on the map).
--
-- FIX: A tiny single-row tick table that every authenticated user may read
--      (it carries no user data). Triggers touch it exactly when presence
--      actually changes:
--        * user_activity row inserted or deleted (first ping / cleanup)
--        * user_activity.is_online flipped (login, explicit logout, the
--          61s stale-online cleanup that replaces a dead heartbeat)
--        * user_session row inserted, revoked-state flipped, or deleted
--      Heartbeat refreshes (last_activity only) intentionally do NOT tick:
--      they would fire for every online user every ~30s with no count change.
--      Clients subscribe to the tick and re-query the count RPCs, which stay
--      SECURITY DEFINER so no presence rows are ever exposed to clients.

BEGIN;

CREATE TABLE IF NOT EXISTS public.presence_tick (
  id integer PRIMARY KEY,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.presence_tick (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.presence_tick ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated can read presence_tick" ON public.presence_tick;
CREATE POLICY "Authenticated can read presence_tick"
  ON public.presence_tick
  FOR SELECT
  TO authenticated
  USING (true);

GRANT SELECT ON public.presence_tick TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.presence_tick FROM authenticated, anon;

DROP FUNCTION IF EXISTS public.touch_presence_tick();
CREATE OR REPLACE FUNCTION public.touch_presence_tick()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.presence_tick
  SET updated_at = now()
  WHERE id = 1;

  RETURN NULL;
END;
$$;

-- user_activity: first-time row insert and row delete.
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_activity_insert_delete ON public.user_activity;
CREATE TRIGGER trg_touch_presence_tick_user_activity_insert_delete
  AFTER INSERT OR DELETE ON public.user_activity
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_presence_tick();

-- user_activity: only actual is_online transitions tick.
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_activity_online_flip ON public.user_activity;
CREATE TRIGGER trg_touch_presence_tick_user_activity_online_flip
  AFTER UPDATE OF is_online ON public.user_activity
  FOR EACH ROW
  WHEN (OLD.is_online IS DISTINCT FROM NEW.is_online)
  EXECUTE FUNCTION public.touch_presence_tick();

-- user_session: registration (new session row).
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_session_insert ON public.user_session;
CREATE TRIGGER trg_touch_presence_tick_user_session_insert
  AFTER INSERT ON public.user_session
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_presence_tick();

-- user_session: revocation / un-revocation (logout, re-login of same device).
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_session_revoke ON public.user_session;
CREATE TRIGGER trg_touch_presence_tick_user_session_revoke
  AFTER UPDATE OF revoked ON public.user_session
  FOR EACH ROW
  WHEN (OLD.revoked IS DISTINCT FROM NEW.revoked)
  EXECUTE FUNCTION public.touch_presence_tick();

-- user_session: session row deletion.
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_session_delete ON public.user_session;
CREATE TRIGGER trg_touch_presence_tick_user_session_delete
  AFTER DELETE ON public.user_session
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_presence_tick();

-- Realtime publication (guarded, same pattern as admin_dashboard_tick).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'presence_tick'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.presence_tick;
    RAISE NOTICE 'presence_tick added to supabase_realtime publication';
  ELSE
    RAISE NOTICE 'presence_tick already in supabase_realtime publication';
  END IF;
END $$;

-- Verify
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename = 'presence_tick';

COMMIT;
