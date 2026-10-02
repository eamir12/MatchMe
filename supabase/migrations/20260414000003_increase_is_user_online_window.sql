-- Increase is_user_online time window to 2 minutes
-- This matches the is_user_truly_visible window and prevents users from being marked offline
-- when the app is in the background (user using other apps) or when timers are throttled by the OS
-- The heartbeat runs every 5-30 seconds, so a 2-minute window provides a good balance

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
        AND ua.last_activity > NOW() - INTERVAL '2 minutes'
    )
), FALSE);
$$;
