-- Reduce online detection window from 30 seconds to 10 seconds
-- This ensures users who kill their app are marked offline faster
-- The heartbeat runs every 20 seconds, so 10 seconds provides a good balance
-- between quick offline detection and avoiding false negatives during normal operation

CREATE OR REPLACE FUNCTION public.is_user_online(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
SELECT COALESCE((
  SELECT
    EXISTS (
      SELECT 1
      FROM public.user_activity ua
      WHERE ua.user_id = p_user_id
        AND ua.is_online = TRUE
        AND ua.last_activity > NOW() - INTERVAL '10 seconds'
    )
), FALSE);
$$;

-- Update is_user_truly_visible to use the same 10-second window for consistency
-- This function is used by get_nearby_users_count to determine if a user should be counted
CREATE OR REPLACE FUNCTION public.is_user_truly_visible(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
SELECT COALESCE((
  SELECT
    (
      EXISTS (
        SELECT 1
        FROM public.user_activity ua
        WHERE ua.user_id = p_user_id
          AND ua.is_online = TRUE
          AND ua.last_activity > NOW() - INTERVAL '10 seconds'
      )
      AND COALESCE(u.user_visibility_setting, false) = TRUE
      AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    )
  FROM public.users u
  WHERE u.id = p_user_id
), FALSE);
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.is_user_online(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_online(UUID) TO anon;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;