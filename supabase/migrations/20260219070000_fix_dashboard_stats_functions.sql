-- Fix dashboard stats functions to correctly count online and nearby users
-- 
-- Requirements:
-- - Online count: Count ALL users currently online (regardless of visibility)
-- - Nearby count: Count users that are BOTH online AND visible within the user's radius
-- - Map: Only show users that are BOTH online AND visible

-- Helper function to check if a user is online (has recent activity)
-- This does NOT check visibility - just online status
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
        AND ua.last_activity > NOW() - INTERVAL '30 seconds'
    )
), FALSE);
$$;

-- Fix get_online_users_count function to count ALL online users (visibility doesn't matter)
-- This includes the current user in the count
CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    -- Count ALL users who are currently online (regardless of visibility)
    -- Include ALL users (the current user is also counted)
    SELECT COUNT(*)
    INTO online_count
    FROM users u
    WHERE public.is_user_online(u.id) = TRUE;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Fix get_nearby_users_count function to count online AND visible users within radius
CREATE OR REPLACE FUNCTION get_nearby_users_count(p_user_id UUID, p_radius_km INTEGER DEFAULT 50)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    nearby_count INTEGER;
    user_lat DOUBLE PRECISION;
    user_lon DOUBLE PRECISION;
BEGIN
    -- Get current user's location
    SELECT latitude, longitude
    INTO user_lat, user_lon
    FROM user_locations
    WHERE user_id = p_user_id
    ORDER BY updated_at DESC
    LIMIT 1;

    -- If user has no location, return 0
    IF user_lat IS NULL OR user_lon IS NULL THEN
        RETURN 0;
    END IF;

    -- Count users within the specified radius who are BOTH online AND visible
    -- Use 30 minute window for location updates (consistent with map function)
    SELECT COUNT(DISTINCT ul.user_id)
    INTO nearby_count
    FROM user_locations ul
    INNER JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id != p_user_id
      AND public.is_user_truly_visible(u.id) = TRUE  -- Must be online AND visible
      -- Simple bounding box filter first (rough approximation)
      AND ul.latitude BETWEEN user_lat - (p_radius_km / 111.0) AND user_lat + (p_radius_km / 111.0)
      AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * COS(RADIANS(user_lat)))) AND user_lon + (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
      -- Use 30 minute window for location recency (consistent with map)
      AND ul.updated_at > NOW() - INTERVAL '30 minutes';

    RETURN COALESCE(nearby_count, 0);
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.is_user_online(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_online(UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_nearby_users_count(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_nearby_users_count(UUID, INTEGER) TO anon;
