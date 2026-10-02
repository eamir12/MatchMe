-- Migration: Fix get_nearby_users_count to accept exact radius in km
-- Date: 2026-06-26
-- Purpose: Change p_radius_km from INTEGER to DOUBLE PRECISION to preserve exact user-specified radius values

-- Drop and recreate get_nearby_users_count with DOUBLE PRECISION parameter
DROP FUNCTION IF EXISTS public.get_nearby_users_count(uuid, integer);

CREATE OR REPLACE FUNCTION public.get_nearby_users_count(p_user_id UUID, p_radius_km DOUBLE PRECISION DEFAULT 50.0)
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

    -- Count nearby users who are both online and visible
    -- Uses bounding box filter with exact radius in km
    SELECT COUNT(DISTINCT ul.user_id)
    INTO nearby_count
    FROM user_locations ul
    JOIN user_activity ua ON ul.user_id = ua.user_id
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id != p_user_id
    AND ua.is_online = true
    AND ua.last_activity > NOW() - INTERVAL '10 seconds'
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    -- Simple bounding box filter for performance (using DOUBLE PRECISION math)
    AND ul.latitude BETWEEN user_lat - (p_radius_km / 111.0) AND user_lat + (p_radius_km / 111.0)
    AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * COS(RADIANS(user_lat)))) 
                         AND user_lon + (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
    AND ul.updated_at > NOW() - INTERVAL '24 hours'; -- Only consider recent locations

    RETURN COALESCE(nearby_count, 0);
END;
$$;

-- Update permissions to match new signature
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision) TO anon;