-- Revert: restore get_online_users_count to count ALL online users globally.
-- The incorrect migration 20260523000000 restricted the count to only
-- users matched with p_user_id. The home screen dashboard should show
-- everyone who is currently using the app.

CREATE OR REPLACE FUNCTION public.get_online_users_count(p_user_id uuid)
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
    AND ua.last_activity > NOW() - INTERVAL '61 seconds';

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
