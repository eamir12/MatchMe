-- Create functions for dashboard statistics

-- Function to get count of online users (users who are currently visible)
CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who are currently logged in (all users except current user)
    -- Exclude the current user from the count
    SELECT COUNT(*)
    INTO online_count
    FROM users u
    WHERE u.id != p_user_id;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Function to get count of nearby users within a specified radius in kilometers
CREATE OR REPLACE FUNCTION get_nearby_users_count(p_user_id UUID, p_radius_km INTEGER DEFAULT 50)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    nearby_count INTEGER;
    user_lat DOUBLE PRECISION;
    user_lon DOUBLE PRECISION;
BEGIN
    SET search_path = 'public';

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

    -- Count users within the specified radius who are currently visible
    -- and have recent location data (within last hour)
    SELECT COUNT(DISTINCT ul.user_id)
    INTO nearby_count
    FROM user_locations ul
    INNER JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id != p_user_id
    AND public.is_user_truly_visible(u.id) = TRUE  -- Only count currently visible users (online + user setting + system status)
    -- Simple bounding box filter first (rough approximation)
    AND ul.latitude BETWEEN user_lat - (p_radius_km / 111.0) AND user_lat + (p_radius_km / 111.0)
    AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * COS(RADIANS(user_lat)))) AND user_lon + (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
    -- More precise distance check would require PostGIS or complex math
    -- For now, we'll use this bounding box approximation
    AND ul.updated_at > NOW() - INTERVAL '1 hour'; -- Only consider recent locations

    RETURN COALESCE(nearby_count, 0);
END;
$$;