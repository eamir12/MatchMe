-- Add RPC for Nearby map: returns obfuscated online+visible user density as grid cells

CREATE OR REPLACE FUNCTION public.get_visible_online_user_map_cells(
  p_requesting_user_id uuid,
  p_center_lat double precision,
  p_center_lng double precision,
  p_radius_km double precision,
  p_cell_meters integer DEFAULT 2000,
  p_recent_minutes integer DEFAULT 30
)
RETURNS TABLE(cell_center_lat double precision, cell_center_lng double precision, user_count integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  earth_km CONSTANT double precision := 6371.0;
  lat_step double precision;
  lng_step double precision;
BEGIN
  IF p_center_lat IS NULL OR p_center_lng IS NULL OR p_radius_km IS NULL OR p_radius_km <= 0 THEN
    RETURN;
  END IF;

  lat_step := GREATEST((p_cell_meters::double precision / 111000.0), 0.0001);
  lng_step := GREATEST((p_cell_meters::double precision / (111000.0 * GREATEST(ABS(COS(RADIANS(p_center_lat))), 0.15))), 0.0001);

  RETURN QUERY
  WITH latest_locations AS (
    SELECT DISTINCT ON (ul.user_id)
      ul.user_id,
      ul.latitude,
      ul.longitude,
      ul.updated_at
    FROM public.user_locations ul
    WHERE ul.user_id IS NOT NULL
      AND ul.user_id <> p_requesting_user_id
      AND ul.updated_at >= NOW() - make_interval(mins => GREATEST(p_recent_minutes, 1))
    ORDER BY ul.user_id, ul.updated_at DESC
  ),
  nearby AS (
    SELECT
      ll.user_id,
      ll.latitude,
      ll.longitude
    FROM latest_locations ll
    WHERE public.is_user_truly_visible(ll.user_id) = TRUE
      AND (earth_km * acos(
        cos(radians(p_center_lat)) * cos(radians(ll.latitude)) * cos(radians(ll.longitude) - radians(p_center_lng))
        + sin(radians(p_center_lat)) * sin(radians(ll.latitude))
      )) <= p_radius_km
  ),
  keyed AS (
    SELECT
      FLOOR(nearby.latitude / lat_step)::bigint AS lat_bucket,
      FLOOR(nearby.longitude / lng_step)::bigint AS lng_bucket,
      nearby.user_id
    FROM nearby
  )
  SELECT
    ((lat_bucket + 0.5) * lat_step)::double precision AS cell_center_lat,
    ((lng_bucket + 0.5) * lng_step)::double precision AS cell_center_lng,
    COUNT(DISTINCT user_id)::integer AS user_count
  FROM keyed
  GROUP BY lat_bucket, lng_bucket
  ORDER BY user_count DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_visible_online_user_map_cells(uuid, double precision, double precision, double precision, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_visible_online_user_map_cells(uuid, double precision, double precision, double precision, integer, integer) TO service_role;
