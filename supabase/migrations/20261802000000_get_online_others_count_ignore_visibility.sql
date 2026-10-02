-- get_online_others_count: number of online users EXCLUDING the caller,
-- regardless of visibility (worldwide), using the same 61s freshness window
-- as get_online_users_count.
--
-- This is the RPC behind the home-screen "online" counter. The client
-- displays `others + 1` because the signed-in user is online by definition
-- the moment they are authenticated — the count therefore never has to wait
-- for the user's own user_activity row / session registration to commit.

CREATE OR REPLACE FUNCTION public.get_online_others_count(p_user_id uuid)
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
  WHERE ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '61 seconds'
    AND ua.user_id != p_user_id;

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO anon;
