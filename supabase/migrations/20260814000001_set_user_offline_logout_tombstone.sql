-- Migration: Leave a revoked tombstone session row on logout
-- Date: 2026-08-14
-- Purpose: Backs the update_user_activity gate for users who have no session
--   rows at all (session registration is skipped when GPS country inference
--   fails — see SessionService.registerSession).
--
--   With only the gate, "no sessions at all" is indistinguishable from
--   "logged in with no sessions", so a stale heartbeat could resurrect a
--   logged-out user who never had a session row. This migration makes
--   set_user_offline insert a revoked tombstone row when the user has zero
--   session rows, so the gate ("offline when revoked rows exist and no
--   active row") blocks resurrection even in that edge case.
--
-- NOTE: Must run as postgres (SQL Editor / supabase db push).

-- Drop every overload of set_user_offline (same pattern as the
-- update_user_activity migration: the live DB may hold extra signatures).
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

CREATE OR REPLACE FUNCTION public.set_user_offline(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  -- Update user_activity table (not users table)
  UPDATE user_activity
  SET is_online = false,
      updated_at = NOW()
  WHERE user_id = p_user_id;

  -- Insert if no record exists
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

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO service_role;

COMMENT ON FUNCTION public.set_user_offline IS
  'Marks a user as offline and leaves a revoked tombstone session row when the user has no sessions.';