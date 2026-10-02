-- Migration: dedupe online rows and count distinct users only
-- Date: 2026-08-15
-- Purpose: prevent a stale or duplicate row in user_activity from making one
--   user appear as multiple online users on the home screen.
--
-- This is a defensive fix for the same-device same-user double-count bug:
-- the app was counting raw rows, not distinct user_ids. If a stale duplicate
-- row exists (for example from older migrations or a previous session that was
-- never fully revoked), the dashboard can show 2 for a single user.

BEGIN;

-- 1) Remove duplicate online rows for the same user, keeping the newest row.
WITH ranked AS (
  SELECT
    ua.ctid,
    ROW_NUMBER() OVER (
      PARTITION BY ua.user_id
      ORDER BY ua.last_activity DESC NULLS LAST,
               ua.updated_at DESC NULLS LAST,
               ua.ctid DESC
    ) AS rn
  FROM public.user_activity ua
)
DELETE FROM public.user_activity ua
USING ranked r
WHERE ua.ctid = r.ctid
  AND r.rn > 1;

-- 2) Enforce one row per user at the database layer.
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_activity_user_id_unique
ON public.user_activity (user_id);

-- 3) Revoke older active duplicate user_session rows for the same user on the
--    same platform/device so an old stale session cannot keep a logged-out user
--    alive in the online count.
WITH ranked_sessions AS (
  SELECT
    us.id,
    ROW_NUMBER() OVER (
      PARTITION BY us.user_id, us.platform, COALESCE(us.device_id, '')
      ORDER BY us.last_active_at DESC NULLS LAST,
               us.created_at DESC NULLS LAST,
               us.id DESC
    ) AS rn
  FROM public.user_session us
  WHERE us.revoked = false
)
UPDATE public.user_session us
SET
  revoked = true,
  revoked_at = COALESCE(us.revoked_at, NOW()),
  terminated_by = COALESCE(us.terminated_by, 'duplicate_guard')
FROM ranked_sessions rs
WHERE us.id = rs.id
  AND rs.rn > 1;

-- 4) Count distinct users, not raw rows.
CREATE OR REPLACE FUNCTION public.get_online_users_count(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(DISTINCT ua.user_id)
  INTO online_count
  FROM public.user_activity ua
  WHERE ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '61 seconds';

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO service_role;

COMMENT ON FUNCTION public.get_online_users_count IS
  'Returns the number of distinct users currently online; prevents same-user double counting from stale/duplicate rows.';

COMMIT;
