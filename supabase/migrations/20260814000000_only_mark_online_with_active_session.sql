-- Migration: Only mark users online when they have an active (non-revoked) session
-- Date: 2026-08-14
-- Purpose: Fix stale online counts after logout.
--
-- Problem: update_user_activity() (the heartbeat RPC) unconditionally sets
--   is_online = true. Any lingering heartbeat — an Android native background
--   service restarted after logout (START_STICKY / WorkManager), an old web
--   tab, a killed process — re-marks a logged-out user as online even though
--   revoke_all_user_sessions()/set_user_offline() already set is_online =
--   false. The home-screen online count then keeps showing 3-4 users on a
--   device where only one person is actually using the app.
--
-- Fix: the heartbeat may only mark a user online if they still have at least
--   one non-revoked user_session row. Logged-out users (whose sessions were
--   revoked or deleted) can never be re-marked online by any client or
--   background process. This makes the server the source of truth.
--
-- NOTE (2026-08-14): registration is best-effort — SessionService skips
--   upsert_user_session when GPS country inference fails, so a logged-in user
--   may legitimately have ZERO session rows. Therefore the gate is:
--     online  = has a non-revoked session, OR has no sessions at all
--     offline = has revoked session(s) but no non-revoked one
--   The "no sessions at all" case is covered on logout by set_user_offline
--   inserting a revoked tombstone row (see the set_user_offline migration),
--   so stale heartbeats can never resurrect a logged-out user.
--
-- NOTE: This migration must run as a superuser (postgres) — e.g. via `supabase
--   db push` or the Supabase Dashboard SQL Editor. Re-assigning ownership
--   first avoids the "must be owner of function update_user_activity" error
--   when the live function was created by an earlier migration under a
--   different owner.

-- Reassign ownership and drop EVERY overload of update_user_activity
-- (the live DB contains both (uuid) and (uuid, text) signatures), so the
-- CREATE below is unambiguous. ALTER/DROP have no IF EXISTS for ALTER and
-- need exact identity arguments when overloads exist, hence the loop.
DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_user_activity'
    LOOP
        EXECUTE format('ALTER FUNCTION public.update_user_activity(%s) OWNER TO postgres', rec.args);
        EXECUTE format('DROP FUNCTION IF EXISTS public.update_user_activity(%s)', rec.args);
    END LOOP;
END $$;

CREATE FUNCTION public.update_user_activity(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    is_visible BOOLEAN;
    is_banned BOOLEAN;
    user_exists BOOLEAN;
    has_active_session BOOLEAN;
    has_revoked_session BOOLEAN;
BEGIN
    SET search_path = 'public';

    -- Check if user exists in the users table
    SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id)
    INTO user_exists;

    -- If user doesn't exist (has been deleted), return early silently
    -- This prevents NULL constraint violations on is_visible
    IF NOT user_exists THEN
        RETURN;
    END IF;

    -- Get current visibility and ban status
    SELECT
        COALESCE(user_visibility_setting, false),
        COALESCE(system_visibility_status, 'visible') = 'banned'
    INTO is_visible, is_banned
    FROM users
    WHERE id = p_user_id;

    -- If user is banned, force offline
    IF is_banned THEN
        UPDATE user_activity
        SET is_online = false,
            last_activity = NOW(),
            updated_at = NOW()
        WHERE user_id = p_user_id;
    ELSE
        -- Session-state gate: a revoked session (logout) must never be
        -- resurrected by a stale heartbeat, but a logged-in user whose
        -- registration was skipped (no GPS country) has no rows at all
        -- and must stay online.
        SELECT EXISTS (
            SELECT 1 FROM user_session
            WHERE user_id = p_user_id AND revoked = false
        )
        INTO has_active_session;

        SELECT EXISTS (
            SELECT 1 FROM user_session
            WHERE user_id = p_user_id AND revoked = true
        )
        INTO has_revoked_session;

        IF (NOT COALESCE(has_active_session, false))
           AND COALESCE(has_revoked_session, false) THEN
            -- Logged out: keep the user offline. Also refresh last_activity
            -- so the 61s online-count window keeps excluding them.
            UPDATE user_activity
            SET is_online = false,
                last_activity = NOW(),
                updated_at = NOW()
            WHERE user_id = p_user_id;
        ELSE
            -- Update activity with current visibility status
            INSERT INTO user_activity (
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
                is_visible,
                NOW()
            )
            ON CONFLICT (user_id)
            DO UPDATE SET
                last_activity = NOW(),
                is_online = true,
                is_visible = EXCLUDED.is_visible,
                updated_at = NOW();
        END IF;
    END IF;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO service_role;

COMMENT ON FUNCTION public.update_user_activity IS
  'Heartbeat RPC. Marks a user online ONLY while they have a non-revoked session; otherwise forces offline.';