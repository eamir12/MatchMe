-- Create function to get online users count excluding the requesting user
-- This is used for the nearby map to show the count of other VISIBLE online users
-- The online map (top right) uses get_online_users_count which includes the current user

CREATE OR REPLACE FUNCTION public.get_online_users_count_excluding_self(p_user_id UUID)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(*)
  INTO online_count
  FROM public.user_activity ua
  INNER JOIN public.users u ON ua.user_id = u.id
  WHERE ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '2 minutes'
    AND ua.user_id != p_user_id
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible';

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;
