-- Incomplete-signup cleanup must remove the auth.users row as well.
--
-- The old body deleted public.user_session and public.users only. The
-- Supabase auth row (and its refresh tokens) survived, so the address stayed
-- registered while the app user was gone.
--
-- It now delegates each stale account to admin_delete_user(), which already
-- owns the exhaustive per-table + storage + auth deletion logic, bounded to
-- 200 accounts per run with per-account error isolation.

BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_incomplete_signup_users()
RETURNS TABLE (
  deleted_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  v_result JSONB;
  v_deleted bigint := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  FOR r IN
    SELECT u.id
    FROM public.users u
    WHERE COALESCE(u.is_profile_complete, false) = false
      AND u.name IS NULL
      AND u.created_at < now() - interval '7 days'
    ORDER BY u.created_at
    LIMIT 200
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      v_result := public.admin_delete_user(r.id);
      IF COALESCE((v_result ->> 'success')::boolean, false) THEN
        v_deleted := v_deleted + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'cleanup_incomplete_signup_users: user % failed: %', r.id, SQLERRM;
    END;
  END LOOP;

  RETURN QUERY SELECT v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_incomplete_signup_users() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_incomplete_signup_users() FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_incomplete_signup_users() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_incomplete_signup_users() TO service_role;

CREATE INDEX IF NOT EXISTS idx_users_incomplete_signup_cleanup
  ON public.users (created_at)
  WHERE is_profile_complete = false AND name IS NULL;

COMMIT;
