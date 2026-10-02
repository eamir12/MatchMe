-- Migration: user-attributed error logging (server + client-reachable)
--
-- Why this instead of relying on postgres_logs:
--   1. Supabase postgres_logs for Realtime (realtime_subscription_manager) log the
--      prepared-statement skeleton ($1..$11) but NOT bind-param values, so a failure
--      like `invalid column for filter receiver_id` contains no user id, no table,
--      no filter value. The failed INSERT also leaves no row in realtime.subscription.
--   2. Log retention / condensed Logflare views strip even more fields.
--   3. An error table keyed by user_id is queryable, joinable to users, and survives
--      log rotation.
--
-- What this creates:
--   public.app_error_log ................. append-only log with user_id
--   public.log_app_error(...) ............ server-side helper (postgres/service_role only)
--   public.report_client_error(...) ...... client-reachable RPC (auth.uid()-checked)
--
-- Patched in this same migration to always carry user_id:
--   public.update_user_visibility(uuid) ... logs + WARNING on failure
--   public.trigger_subscription_normalization() .. per-user log + continue
--   public.scheduled_subscription_normalization() .. log + re-raise

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_error_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL,
  user_id uuid NULL,
  app_version text NULL,
  error_message text NOT NULL,
  context jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_app_error_log_created_at ON public.app_error_log (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_error_log_user_id ON public.app_error_log (user_id);
CREATE INDEX IF NOT EXISTS idx_app_error_log_source ON public.app_error_log (source);

ALTER TABLE public.app_error_log ENABLE ROW LEVEL SECURITY;

-- No direct client access: all writes go through SECURITY DEFINER RPCs below.
REVOKE ALL ON TABLE public.app_error_log FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.app_error_log IS 'Append-only user-attributed error log. Server functions and clients (via report_client_error) write here so failures always carry user_id.';

-- ---------------------------------------------------------------------------
-- 2. Server-side helper (postgres / service_role only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_app_error(
  p_source text,
  p_user_id uuid,
  p_error_message text,
  p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.app_error_log (source, user_id, app_version, error_message, context)
  VALUES (
    substr(COALESCE(NULLIF(btrim(p_source), ''), 'unknown'), 1, 64),
    p_user_id,
    NULL,
    substr(COALESCE(p_error_message, ''), 1, 2000),
    COALESCE(p_context, '{}'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.log_app_error(text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_app_error(text, uuid, text, jsonb) TO postgres, service_role;

-- ---------------------------------------------------------------------------
-- 3. Client-reachable reporter (Android background service, Flutter, etc.)
--    Auth-checked: p_user_id must equal auth.uid() unless caller is service_role.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_client_error(
  p_source text,
  p_error_message text,
  p_user_id uuid DEFAULT auth.uid(),
  p_app_version text DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'missing user_id';
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_source IS NULL OR btrim(p_source) = '' THEN
    RAISE EXCEPTION 'missing source';
  END IF;

  IF p_error_message IS NULL OR btrim(p_error_message) = '' THEN
    RAISE EXCEPTION 'missing error_message';
  END IF;

  INSERT INTO public.app_error_log (source, user_id, app_version, error_message, context)
  VALUES (
    substr(btrim(p_source), 1, 64),
    v_user_id,
    substr(NULLIF(btrim(COALESCE(p_app_version, '')), ''), 1, 32),
    substr(p_error_message, 1, 2000),
    COALESCE(p_context, '{}'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.report_client_error(text, text, uuid, text, jsonb) IS 'Client error reporter. p_user_id must equal auth.uid(). Used by Android background service phx_reply failures and Flutter realtime error callbacks.';

-- ---------------------------------------------------------------------------
-- 4. Patch update_user_visibility: correct columns + log user_id on failure
--    (Deployed version referenced user_activity.last_active_at which does not
--    exist; user_activity uses last_activity, last_active_at lives on user_session.)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_activity' AND column_name = 'is_visible'
  ) THEN
    ALTER TABLE public.user_activity ADD COLUMN is_visible BOOLEAN NOT NULL DEFAULT true;
    UPDATE public.user_activity ua
    SET is_visible = COALESCE(u.user_visibility_setting, false)
    FROM public.users u WHERE ua.user_id = u.id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.update_user_visibility(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  visibility_value BOOLEAN;
BEGIN
  SELECT COALESCE(u.user_visibility_setting, false)
  INTO visibility_value
  FROM public.users u
  WHERE u.id = p_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  UPDATE public.user_activity
  SET is_visible = visibility_value,
      updated_at = NOW()
  WHERE user_id = p_user_id;

  IF NOT FOUND THEN
    INSERT INTO public.user_activity (user_id, last_activity, is_online, is_visible, updated_at)
    VALUES (p_user_id, NOW(), false, visibility_value, NOW())
    ON CONFLICT (user_id) DO UPDATE SET
      is_visible = EXCLUDED.is_visible,
      updated_at = NOW();
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Persist with user_id so it is queryable even if log drains drop WARNINGs.
  BEGIN
    PERFORM public.log_app_error(
      'update_user_visibility', p_user_id, SQLERRM,
      jsonb_build_object('sqlstate', SQLSTATE)
    );
  EXCEPTION WHEN OTHERS THEN
    NULL; -- logging must never mask the original error
  END;
  RAISE WARNING 'Error updating visibility for user %: %', p_user_id, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO anon;

-- ---------------------------------------------------------------------------
-- 5. Patch subscription normalization: per-user log + continue (one bad user
--    must not abort the whole 5-min cron batch), outer failure logged + raised.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_subscription_normalization()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT u.id AS user_id
    FROM public.users u
    LEFT JOIN public.user_subscription_queue sq
      ON sq.user_id = u.id
      AND sq.status = 'pending'
      AND sq.starts_at <= now()
    WHERE (u.subscription_tier IS NOT NULL AND u.subscription_tier <> 'free'
           AND u.subscription_expires_at IS NOT NULL AND u.subscription_expires_at <= now())
       OR sq.id IS NOT NULL
  LOOP
    BEGIN
      PERFORM public._normalize_user_subscription_queue_internal(r.user_id);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM public.log_app_error(
          'trigger_subscription_normalization', r.user_id, SQLERRM,
          jsonb_build_object('sqlstate', SQLSTATE)
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
      RAISE WARNING 'Error normalizing subscription for user %: %', r.user_id, SQLERRM;
      CONTINUE;
    END;
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    PERFORM public.log_app_error(
      'trigger_subscription_normalization', NULL, SQLERRM,
      jsonb_build_object('sqlstate', SQLSTATE, 'scope', 'outer')
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.scheduled_subscription_normalization()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.trigger_subscription_normalization();
EXCEPTION WHEN OTHERS THEN
  BEGIN
    PERFORM public.log_app_error(
      'scheduled_subscription_normalization', NULL, SQLERRM,
      jsonb_build_object('sqlstate', SQLSTATE)
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RAISE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.trigger_subscription_normalization() TO authenticated;
GRANT EXECUTE ON FUNCTION public.scheduled_subscription_normalization() TO postgres, service_role;
