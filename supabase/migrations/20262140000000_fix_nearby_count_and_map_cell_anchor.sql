-- Migration: Nearby count and nearby map cells must agree
-- Date: 2026-10-20
-- Depends on: 20262014000000 (pinned location freshness exemptions)
--
-- The Nearby Map screen showed two independent numbers side by side:
--
--   * the "Showing ~N users" pill -> get_nearby_users_count()
--   * the plotted cell markers    -> get_visible_online_user_map_cells()
--
-- Nothing tied the two together and they did not even use the same
-- geometry:
--
--   * get_nearby_users_count() anchored its query on the server's own copy
--     of the requesting user's position (user_locations) and returned 0
--     outright when that row was missing.
--   * get_visible_online_user_map_cells() is anchored on the position the
--     client sends in (the device's live fix, or the active pin).
--
-- Whenever the server-side copy was missing or stale the pill read 0 while
-- a real user was plotted right next to the "You" marker. That happens
-- routinely: the Nearby Map screen never publishes the user's own position
-- (only the Online World Map does), cleanup_old_user_locations() reaps rows
-- older than 15 minutes, and an invisible user stops uploading GPS
-- entirely - but the map keeps working because it is anchored on the
-- device, not on the server's copy.
--
-- Fixes:
--   1. get_nearby_users_count() accepts an optional client-supplied anchor
--      (p_center_lat / p_center_lng) so the count is centred on the exact
--      same point as the cell query. The server-side position stays as the
--      fallback for callers that do not know their own position.
--   2. get_visible_online_user_map_cells() clamps the acos() argument the
--      same way the count already does. A float a hair above 1.0 made
--      acos() return NULL, and "NULL <= radius" is NULL, so a user inside
--      the radius was counted by one query and silently dropped by the
--      other.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Nearby count: optional client-supplied anchor.
--    (Same shape as 20262014000000 section 3, plus the anchor parameters and
--    a longitude pre-filter that can no longer collapse to a division by
--    zero near the poles.)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_nearby_users_count(uuid, double precision);

CREATE OR REPLACE FUNCTION public.get_nearby_users_count(
  p_user_id UUID,
  p_radius_km DOUBLE PRECISION DEFAULT 50.0,
  p_center_lat DOUBLE PRECISION DEFAULT NULL,
  p_center_lng DOUBLE PRECISION DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    nearby_count INTEGER;
    user_lat DOUBLE PRECISION;
    user_lon DOUBLE PRECISION;
    earth_km CONSTANT double precision := 6371.0;
BEGIN
    -- Anchor: the position the caller is actually looking from. The nearby
    -- map passes the device's live fix (or the active pin) so the count and
    -- the plotted cells share one centre. Without it we fall back to the
    -- server's copy of the requesting user's position.
    IF p_center_lat IS NOT NULL AND p_center_lng IS NOT NULL THEN
        user_lat := p_center_lat;
        user_lon := p_center_lng;
    ELSE
        SELECT latitude, longitude
        INTO user_lat, user_lon
        FROM public.user_locations
        WHERE user_id = p_user_id
        ORDER BY updated_at DESC
        LIMIT 1;

        -- No known position at all: there is no centre to measure from.
        IF user_lat IS NULL OR user_lon IS NULL THEN
            RETURN 0;
        END IF;
    END IF;

    -- Count nearby users who are truly visible (online within 61s + visibility
    -- settings) and within the exact selected radius.
    -- Bounding box pre-filter keeps the haversine check cheap.
    SELECT COUNT(*)
    INTO nearby_count
    FROM (
        SELECT DISTINCT ON (ul.user_id)
            ul.user_id,
            ul.latitude,
            ul.longitude
        FROM public.user_locations ul
        WHERE ul.user_id <> p_user_id
          AND (
            ul.updated_at > NOW() - INTERVAL '30 minutes'
            OR (COALESCE(ul.is_pinned, FALSE) AND ul.pinned_expires_at > NOW())
          )
          AND ul.latitude BETWEEN user_lat - (p_radius_km / 111.0) AND user_lat + (p_radius_km / 111.0)
          AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * GREATEST(ABS(COS(RADIANS(user_lat))), 0.15)))
                               AND user_lon + (p_radius_km / (111.0 * GREATEST(ABS(COS(RADIANS(user_lat))), 0.15)))
        ORDER BY ul.user_id, ul.updated_at DESC
    ) candidate
    WHERE public.is_user_truly_visible(candidate.user_id) = TRUE
      AND (earth_km * acos(
            LEAST(1.0, GREATEST(-1.0,
              cos(radians(user_lat)) * cos(radians(candidate.latitude))
                * cos(radians(candidate.longitude) - radians(user_lon))
              + sin(radians(user_lat)) * sin(radians(candidate.latitude))
            ))
          )) <= p_radius_km;

    RETURN COALESCE(nearby_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision, double precision, double precision) TO anon;

COMMENT ON FUNCTION public.get_nearby_users_count(uuid, double precision, double precision, double precision) IS
  'Counts users within p_radius_km of the anchor. The anchor is the caller-supplied position (p_center_lat/p_center_lng) when given - the same point the nearby map queries its cells from - and falls back to the requesting user''s own user_locations row otherwise.';

-- ---------------------------------------------------------------------------
-- 2. Nearby map cells: clamp the acos() argument so a float above 1.0 can
--    no longer turn the distance check into NULL and drop a user that is
--    inside the radius. (Same shape as 20262014000000 section 4.)
-- ---------------------------------------------------------------------------
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
      AND (
        ul.updated_at >= NOW() - make_interval(mins => GREATEST(p_recent_minutes, 1))
        OR (COALESCE(ul.is_pinned, FALSE) AND ul.pinned_expires_at > NOW())
      )
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
        LEAST(1.0, GREATEST(-1.0,
          cos(radians(p_center_lat)) * cos(radians(ll.latitude)) * cos(radians(ll.longitude) - radians(p_center_lng))
          + sin(radians(p_center_lat)) * sin(radians(ll.latitude))
        ))
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

COMMIT;
