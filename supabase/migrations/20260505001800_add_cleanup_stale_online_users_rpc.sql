-- Migration: Add RPC function to cleanup stale online users
-- Date: 2026-05-05
-- Purpose: Automatically set is_online = false for users whose last_activity is older than 61 seconds
-- This ensures real-time online count accuracy and triggers real-time UPDATE events

CREATE OR REPLACE FUNCTION public.cleanup_stale_online_users()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  updated_count INTEGER;
BEGIN
  -- Update users who are marked online but haven't had activity in 61+ seconds
  -- The 61-second threshold matches get_online_users_count() for consistency
  UPDATE user_activity 
  SET is_online = false,
      updated_at = NOW()
  WHERE is_online = true 
    AND last_activity < NOW() - INTERVAL '61 seconds';

  -- Get the number of rows affected
  GET DIAGNOSTICS updated_count = ROW_COUNT;

  RETURN updated_count;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.cleanup_stale_online_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_online_users() TO anon;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_online_users() TO service_role;

COMMENT ON FUNCTION public.cleanup_stale_online_users() IS 
  'Sets is_online=false for users with last_activity older than 61 seconds. Returns count of users updated.';
