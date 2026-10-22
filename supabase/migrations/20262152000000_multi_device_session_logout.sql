-- Migration: Per-device logout without dropping other active devices
-- Date: 2026-10-22
--
-- Problem:
--   The client logout path called set_user_offline() and then
--   revoke_all_user_sessions(). A user signed in on several devices was
--   therefore marked offline (and all of their sessions were revoked) as soon
--   as one device signed out, even though the other devices were still running,
--   heartbeating and uploading locations. The user disappeared from the online
--   count / online map until one of the remaining devices happened to
--   re-register its session.
--
-- Fix:
--   1. NEW logout_user_device() RPC: revokes only the calling device's
--      user_session row and then asks set_user_offline() to update presence.
--      It returns TRUE when at least one other session is still active.
--   2. set_user_offline() is now session-aware: it only forces the account
--      offline (and only clears an active pinned location) when NO non-revoked
--      session remains. If another device is still logged in, presence and the
--      account-level pin are left untouched. Calls without a device session
--      (web page-unload beacon, transient background connectivity loss) keep
--      the same safe behaviour.
--   3. sync_user_activity_on_session_change() now derives is_online from "does
--      ANY non-revoked session remain?" instead of "is the row that changed
--      non-revoked?". Revoking one device, or inserting a revoked tombstone,
--      can no longer flip an account with other active devices offline.
--
-- The existing update_user_activity() heartbeat gate already keys off ANY
-- non-revoked session, so the remaining devices keep the user online through
-- their normal heartbeats and location updates.

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Session-change trigger: online if ANY active session remains
-- ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sync_user_activity_on_session_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_has_active_session boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_user_id := OLD.user_id;
  ELSE
    v_user_id := NEW.user_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- An account is online while it has at least one non-revoked session.
  -- Revoking one device (or inserting a logout tombstone) must not take the
  -- account offline while another device is still signed in.
  SELECT EXISTS (
    SELECT 1
    FROM public.user_session
    WHERE user_id = v_user_id
      AND revoked = false
  )
  INTO v_has_active_session;

  INSERT INTO public.user_activity (
    user_id,
    is_online,
    last_activity,
    updated_at
  )
  VALUES (
    v_user_id,
    COALESCE(v_has_active_session, false),
    NOW(),
    NOW()
  )
  ON CONFLICT (user_id)
  DO UPDATE SET
    is_online = EXCLUDED.is_online,
    last_activity = NOW(),
    updated_at = NOW();

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.sync_user_activity_on_session_change() IS
  'Syncs user_activity.is_online from ANY remaining non-revoked session, so signing out one device keeps the account online while other devices are active.';

-- ───────────────────────────────────────────────────────────────────────────
-- 2. set_user_offline: only go offline when no active session remains
-- ───────────────────────────────────────────────────────────────────────────

-- Drop every overload so the recreated signature is unambiguous (same pattern
-- used by the earlier set_user_offline migrations).
DO $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_user_offline'
  LOOP
    EXECUTE format('ALTER FUNCTION public.set_user_offline(%s) OWNER TO postgres', rec.args);
    EXECUTE format('DROP FUNCTION IF EXISTS public.set_user_offline(%s)', rec.args);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.set_user_offline(
  p_user_id uuid,
  p_clear_pinned boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_active_session boolean;
  v_is_banned boolean;
  v_is_visible boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.user_session
    WHERE user_id = p_user_id
      AND revoked = false
  )
  INTO v_has_active_session;

  SELECT
    COALESCE(system_visibility_status, 'visible') = 'banned',
    COALESCE(user_visibility_setting, false)
  INTO v_is_banned, v_is_visible
  FROM public.users
  WHERE id = p_user_id;

  -- Another device is still signed in (and the account is not banned): the
  -- account stays online and its visibility setting is preserved. Do not clear
  -- an account-level pinned location either — that pin is still in use by the
  -- remaining device(s).
  IF COALESCE(v_has_active_session, false)
     AND NOT COALESCE(v_is_banned, false) THEN
    INSERT INTO public.user_activity (
      user_id,
      last_activity,
      is_online,
      is_visible,
      updated_at
    )
    VALUES (
      p_user_id,
      NOW(),
      true,
      COALESCE(v_is_visible, false),
      NOW()
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
      is_online = true,
      updated_at = NOW();

    RETURN;
  END IF;

  -- No active session remains (or the account is banned): mark offline.
  UPDATE public.user_activity
  SET is_online = false,
      last_activity = NOW(),
      updated_at = NOW()
  WHERE user_id = p_user_id;

  INSERT INTO public.user_activity (
    user_id,
    last_activity,
    is_online,
    is_visible,
    updated_at
  )
  SELECT
    p_user_id,
    NOW(),
    false,
    COALESCE((SELECT user_visibility_setting FROM public.users WHERE id = p_user_id), false),
    NOW()
  WHERE NOT EXISTS (
    SELECT 1 FROM public.user_activity WHERE user_id = p_user_id
  );

  -- Explicit logout clears the user's pinned location so they are not counted
  -- online via is_pinned_location_active(). Transient-offline callers leave
  -- p_clear_pinned = FALSE so a pin survives a network hiccup.
  IF COALESCE(p_clear_pinned, false) THEN
    UPDATE public.user_locations
    SET is_pinned = FALSE,
        pinned_expires_at = NULL,
        pinned_created_at = NULL,
        pinned_label = NULL,
        updated_at = NOW()
    WHERE user_id = p_user_id
      AND COALESCE(is_pinned, FALSE) = TRUE;
  END IF;

  -- Logout tombstone: if the user has no session rows at all (e.g. their
  -- session registration was skipped because GPS country inference failed),
  -- leave a revoked row so the update_user_activity gate keeps them offline
  -- against stale background heartbeats.
  INSERT INTO public.user_session (
    id,
    user_id,
    platform,
    revoked,
    revoked_at,
    terminated_by,
    last_active_at,
    created_at
  )
  SELECT
    gen_random_uuid(),
    p_user_id,
    'logout',
    true,
    NOW(),
    'user',
    NOW(),
    NOW()
  WHERE NOT EXISTS (
    SELECT 1 FROM public.user_session WHERE user_id = p_user_id
  )
  ON CONFLICT (id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO anon;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO service_role;
REVOKE EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) FROM PUBLIC;

COMMENT ON FUNCTION public.set_user_offline(uuid, boolean) IS
  'Marks a user offline only when no non-revoked session remains; when another device is still signed in, presence (and the active pin) is preserved. When p_clear_pinned is true and the account really goes offline, also clears any active pinned location.';

-- ───────────────────────────────────────────────────────────────────────────
-- 3. logout_user_device: revoke THIS device only, then update presence
-- ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.logout_user_device(
  p_user_id uuid,
  p_session_id uuid DEFAULT NULL,
  p_platform text DEFAULT NULL,
  p_device_id text DEFAULT NULL,
  p_clear_pinned boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_platform text;
  v_device_id text;
  v_has_active_session boolean;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  IF COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    IF auth.uid() IS NULL OR auth.uid()::uuid <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to end sessions for other users';
    END IF;
  END IF;

  v_platform := NULLIF(btrim(COALESCE(p_platform, '')), '');
  v_device_id := NULLIF(btrim(COALESCE(p_device_id, '')), '');

  -- Match the caller's own session. The device_id fallback covers a stale
  -- locally stored session id on web/Android/iOS; it is deliberately only
  -- used when a concrete device_id is available so desktop platforms never
  -- revoke another machine's session.
  UPDATE public.user_session
  SET revoked = true,
      revoked_at = COALESCE(revoked_at, NOW()),
      logout_at = NOW(),
      terminated_by = 'user'
  WHERE user_id = p_user_id
    AND revoked = false
    AND (
      (p_session_id IS NOT NULL AND id = p_session_id)
      OR (
        p_session_id IS NULL
        AND v_device_id IS NOT NULL
        AND v_platform IS NOT NULL
        AND platform = v_platform
        AND device_id = v_device_id
      )
    );

  PERFORM public.set_user_offline(
    p_user_id,
    COALESCE(p_clear_pinned, true)
  );

  SELECT EXISTS (
    SELECT 1
    FROM public.user_session
    WHERE user_id = p_user_id
      AND revoked = false
  )
  INTO v_has_active_session;

  RETURN COALESCE(v_has_active_session, false);
END;
$$;

GRANT EXECUTE ON FUNCTION public.logout_user_device(uuid, uuid, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.logout_user_device(uuid, uuid, text, text, boolean) TO service_role;
REVOKE EXECUTE ON FUNCTION public.logout_user_device(uuid, uuid, text, text, boolean) FROM PUBLIC;

COMMENT ON FUNCTION public.logout_user_device IS
  'Ends only the calling device''s session (or the session matching its platform/device id) and keeps the account online/visible while other devices still have active sessions. Returns TRUE when at least one other session remains active.';

COMMIT;
