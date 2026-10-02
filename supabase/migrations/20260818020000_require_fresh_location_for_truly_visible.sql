-- Make is_user_truly_visible require a fresh location row.
--
-- Rationale: the product already requires a recent location everywhere
-- that matters:
--   * perform_continuous_user_matching() only considers users with
--     user_locations.updated_at >= now() - 5 minutes (matching pool)
--   * get_nearby_users_count() / nearby_map_cells_rpc() operate on
--     user_locations rows and only then filter by is_user_truly_visible
--   * cleanup_old_user_locations() deletes location rows older than
--     5 minutes (privacy)
--
-- A user who is "visible" (heartbeat + opt-in) but has no fresh location
-- row cannot be matched, cannot be seen nearby, and cannot be located by
-- admins — treating them as visible is therefore misleading everywhere.
-- Adding the location requirement here (single point) aligns the admin
-- live visible counts/drilldowns (which call this function) with the
-- matching pool and the nearby map, with no behavior change to matching
-- or nearby features.
--
-- NOTE: window relaxed from 5m to 15m (2026-08) to survive background
-- stationary throttling (GPS 60s) and iOS significant-change-only delivery
-- plus Doze delays without dropping visible counts/maps a minute after
-- screen-off. Matching pool still uses 5m; this only widens admin
-- visibility grace so background users stay visible while native heartbeat
-- catches up. Privacy cleanup still 5m (row deleted => not visible anyway).

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

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;