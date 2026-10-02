BEGIN;

-- Cleanup function for incomplete signup users
-- Deletes users who never completed their profile (name IS NULL) after 7 days
-- Cleans up related rows to avoid orphans: user_session, user_chat_keys (via CASCADE), etc.
CREATE OR REPLACE FUNCTION public.cleanup_incomplete_signup_users()
RETURNS TABLE (
  deleted_count bigint
) LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_count bigint;
BEGIN
  WITH stale_users AS (
    SELECT id FROM public.users
    WHERE is_profile_complete = false
      AND name IS NULL
      AND created_at < now() - interval '7 days'
  ),
  deleted_sessions AS (
    DELETE FROM public.user_session
    WHERE user_id IN (SELECT id FROM stale_users)
  )
  DELETE FROM public.users
  WHERE id IN (SELECT id FROM stale_users);

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  RETURN QUERY SELECT v_deleted_count;
END;
$$;

COMMIT;
