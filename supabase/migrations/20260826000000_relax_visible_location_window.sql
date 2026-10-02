-- Relax is_user_truly_visible location window 5m -> 15m
-- and cleanup default 5 -> 15 so background-stationary users survive Doze/throttle.
-- Without this, visible/maps drop ~5m after screen-off even though online heartbeat (30s) is fine.
-- See also edits to cron-jobs/index.ts p_minutes_old:5->15 and LocationWorker chained heartbeat.

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
          AND ua.last_activity > NOW() - INTERVAL '61 seconds'
      )
      AND COALESCE(u.user_visibility_setting, false) = TRUE
      AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
      AND EXISTS (
        SELECT 1
        FROM public.user_locations ul
        WHERE ul.user_id = p_user_id
          AND ul.updated_at >= NOW() - INTERVAL '15 minutes'
      )
    )
  FROM public.users u
  WHERE u.id = p_user_id
), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;

-- Also bump cleanup default to 15m so row isn't deleted before the check expires
CREATE OR REPLACE FUNCTION public.cleanup_old_user_locations(p_minutes_old int DEFAULT 15)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted int := 0;
  v_cutoff timestamptz;
BEGIN
  v_cutoff := now() - (p_minutes_old || ' minutes')::interval;
  DELETE FROM public.user_locations WHERE updated_at < v_cutoff;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_old_user_locations(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_old_user_locations(int) TO authenticated;
