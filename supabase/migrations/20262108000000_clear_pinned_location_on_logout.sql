-- Migration: Clear pinned location on logout + fire presence_tick on pin changes
-- Date: 2026-10-21
--
-- Problem 1 (shared-device stale online count):
--   When a user logs out, set_user_offline() sets is_online=false and
--   revoke_all_user_sessions() revokes their sessions. But if the user had
--   an active pinned location (home-base pin), is_pinned_location_active()
--   still returns TRUE, so the online count keeps including them — even on a
--   shared device where another account has already replaced them. A user who
--   explicitly signs out must never remain "online" via a stale pin.
--
-- Problem 2 (slow count refresh when pin state changes):
--   presence_tick is only touched by user_activity / user_session triggers.
--   When a pin is set, expires (cron), or is cleared, the tick table is NOT
--   updated, so clients that rely on it (Home online count, online world map
--   country markers, admin LIVE cards) wait for their periodic fallback timer
--   (up to 5 minutes on Home, 30s on the map) instead of refreshing instantly.
--
-- Fix:
--   1. set_user_offline gains an optional p_clear_pinned flag (default FALSE
--      so transient-offline callers are unaffected). On explicit logout the
--      caller passes TRUE, which clears the user's pinned location so
--      is_pinned_location_active() returns FALSE immediately. last_activity
--      is also bumped so the 61s online window starts at logout time.
--   2. sync_pinned_location_to_users now also touches presence_tick whenever
--      the visible pin state actually changes (set / expire / clear / row
--      delete), so every client relying on the tick refreshes its count
--      instantly. GPS heartbeats that only bump updated_at still do NOT tick.

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1. set_user_offline: optional pin clearing + last_activity bump
-- ───────────────────────────────────────────────────────────────────────────

-- Drop every overload so the new signature (with p_clear_pinned default) is
-- unambiguous, same pattern as prior set_user_offline migrations.
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
SET search_path = 'public'
AS $$
BEGIN
    -- Mark the user offline. Bump last_activity too so the 61s online-count
    -- window starts at logout time: even if a stale heartbeat races and sets
    -- is_online=true before sessions are revoked, the count will drop once
    -- this last_activity timestamp ages out (and the session gate forces
    -- is_online back to false on the next heartbeat anyway).
    UPDATE user_activity
    SET is_online = false,
        last_activity = NOW(),
        updated_at = NOW()
    WHERE user_id = p_user_id;

    -- Insert a row if none exists (e.g. first-time user who never pinged).
    INSERT INTO user_activity (
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
        COALESCE((SELECT user_visibility_setting FROM users WHERE id = p_user_id), false),
        NOW()
    WHERE NOT EXISTS (SELECT 1 FROM user_activity WHERE user_id = p_user_id);

    -- On explicit logout, clear any active pinned location so
    -- is_pinned_location_active() returns FALSE immediately. Without this a
    -- logged-out user stays "online" via their home-base pin until it expires,
    -- which on a shared device makes two accounts appear online at once.
    -- Transient-offline callers (background service losing connectivity)
    -- leave p_clear_pinned = FALSE so the pin survives a network hiccup.
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
    -- against stale background heartbeats. The session-change trigger flips
    -- user_activity.is_online=false for this insert, consistent with the above.
    INSERT INTO user_session (
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
    WHERE NOT EXISTS (SELECT 1 FROM user_session WHERE user_id = p_user_id)
    ON CONFLICT (id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO anon;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid, boolean) TO service_role;

COMMENT ON FUNCTION public.set_user_offline(uuid, boolean) IS
  'Marks a user offline. When p_clear_pinned is true (explicit logout), also clears any active pinned location so the user is not counted online via is_pinned_location_active().';

-- ───────────────────────────────────────────────────────────────────────────
-- 2. sync_pinned_location_to_users: also touch presence_tick on real pin changes
-- ───────────────────────────────────────────────────────────────────────────
--
-- The tick must fire exactly when the pin's "active" state changes so every
-- client that subscribes to presence_tick (Home online count, online world
-- map country markers, admin LIVE cards) refreshes instantly. GPS heartbeats
-- that only bump user_locations.updated_at do NOT change is_pinned /
-- pinned_expires_at, so they still do NOT tick (same throttle as before).

CREATE OR REPLACE FUNCTION public.sync_pinned_location_to_users()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_active BOOLEAN;
    v_expires TIMESTAMPTZ;
BEGIN
    -- DELETE (account removal): clear the mirror so partners converge to false.
    IF TG_OP = 'DELETE' THEN
        UPDATE public.users
        SET is_pinned_location_active = FALSE,
            pinned_expires_at = NULL
        WHERE id = OLD.user_id
          AND (
            is_pinned_location_active IS DISTINCT FROM FALSE
            OR pinned_expires_at IS NOT NULL
          );
        -- Pin state changed (removed), so notify presence subscribers.
        UPDATE public.presence_tick SET updated_at = now() WHERE id = 1;
        RETURN OLD;
    END IF;

    v_expires := NEW.pinned_expires_at;
    v_active := (
        COALESCE(NEW.is_pinned, FALSE) = TRUE
        AND v_expires IS NOT NULL
        AND v_expires > NOW()
    );

    -- Only touch users when the visible pin state actually changed. This
    -- avoids spamming users-realtime on every GPS heartbeat:
    -- touch_active_pinned_locations() bumps user_locations.updated_at every
    -- ~4 min WITHOUT changing is_pinned/pinned_expires_at.
    IF TG_OP = 'INSERT'
       OR OLD.is_pinned IS DISTINCT FROM NEW.is_pinned
       OR OLD.pinned_expires_at IS DISTINCT FROM NEW.pinned_expires_at
    THEN
        UPDATE public.users
        SET is_pinned_location_active = v_active,
            pinned_expires_at = v_expires
        WHERE id = NEW.user_id
          AND (
            is_pinned_location_active IS DISTINCT FROM v_active
            OR pinned_expires_at IS DISTINCT FROM v_expires
          );

        -- The pin's active state may have changed (set, expired, cleared, or
        -- the first location row was inserted). Notify all presence_tick
        -- subscribers so online counts + country markers refresh instantly
        -- instead of waiting for the periodic fallback timer.
        UPDATE public.presence_tick SET updated_at = now() WHERE id = 1;
    END IF;
    RETURN NEW;
END;
$$;

-- Re-create the trigger to bind the updated function.
DROP TRIGGER IF EXISTS trg_sync_pinned_to_users ON public.user_locations;
CREATE TRIGGER trg_sync_pinned_to_users
    AFTER INSERT OR UPDATE OR DELETE ON public.user_locations
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_pinned_location_to_users();

COMMIT;
