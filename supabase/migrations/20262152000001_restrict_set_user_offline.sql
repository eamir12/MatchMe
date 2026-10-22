-- Harden presence updates after the multi-device logout rollout.
--
-- set_user_offline used to be callable by anon because the web page-close
-- path used navigator.sendBeacon(), which cannot attach an Authorization
-- header. That allowed unauthenticated callers to mutate presence for any
-- UUID. The web client now sends an authenticated keepalive fetch instead, so
-- only authenticated users (and service_role) may call this RPC.
--
-- The function also rejects attempts by one authenticated user to update
-- another user's presence. service_role keeps its trusted cross-user access.

BEGIN;

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
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  IF COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    IF auth.uid() IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'Not authorized to update presence for other users';
    END IF;
  END IF;

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
  -- an account-level pinned location either - that pin is still in use by the
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

REVOKE EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO service_role;

COMMENT ON FUNCTION public.set_user_offline(uuid, boolean) IS
  'Marks the calling user offline only when no non-revoked session remains; service_role may target any user. Authenticated users can only target themselves.';

COMMIT;
