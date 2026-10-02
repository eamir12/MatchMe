-- Migration: Create get_potential_matches server-side function
-- Phase 6: Replace client-side distance filtering with server-side computation.
-- Uses Haversine formula (same as existing find_nearby_users) but also
-- excludes already-matched users and unmatched pairs.
-- No PostGIS dependency.

CREATE OR REPLACE FUNCTION public.get_potential_matches(
  p_user_id UUID,
  p_latitude DOUBLE PRECISION,
  p_longitude DOUBLE PRECISION,
  p_radius_km DOUBLE PRECISION DEFAULT 50
)
RETURNS TABLE(
  user_id UUID,
  distance_km DOUBLE PRECISION,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  display_name TEXT,
  profile_data JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  earth_km CONSTANT DOUBLE PRECISION := 6371.0;
BEGIN
  RETURN QUERY
  SELECT
    ul.user_id,
    (earth_km * acos(
      cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
      cos(radians(ul.longitude) - radians(p_longitude)) +
      sin(radians(p_latitude)) * sin(radians(ul.latitude))
    ))::DOUBLE PRECISION AS distance_km,
    ul.latitude,
    ul.longitude,
    u.display_name,
    u.profile_data
  FROM public.user_locations ul
  INNER JOIN public.users u ON u.id = ul.user_id
  WHERE ul.user_id != p_user_id
    AND u.user_visibility_setting = true
    AND u.system_visibility_status = 'visible'
    AND ul.latitude IS NOT NULL
    AND ul.longitude IS NOT NULL
    AND ul.updated_at >= NOW() - INTERVAL '30 minutes'
    AND NOT EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user1_id = p_user_id AND m.user2_id = ul.user_id)
         OR (m.user1_id = ul.user_id AND m.user2_id = p_user_id)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.unmatched_pairs up
      WHERE (up.user1_id = p_user_id AND up.user2_id = ul.user_id)
         OR (up.user1_id = ul.user_id AND up.user2_id = p_user_id)
    )
    AND (earth_km * acos(
      cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
      cos(radians(ul.longitude) - radians(p_longitude)) +
      sin(radians(p_latitude)) * sin(radians(ul.latitude))
    )) <= p_radius_km
  ORDER BY distance_km ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_potential_matches(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

-- Also grant to anon for initial loading before auth
GRANT EXECUTE ON FUNCTION public.get_potential_matches(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;
