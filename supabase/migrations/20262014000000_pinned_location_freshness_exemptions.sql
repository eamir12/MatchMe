-- Migration: Pinned home-base location, step 2 — freshness exemptions (no new table)
-- Date: 2026-09-18
-- Depends on: 20262013000000 (pin columns + pin/extend/unpin RPCs + update_user_location guard)
--
-- Design note: perform_continuous_user_matching() is deliberately NOT rewritten here.
-- It is 150+ lines, has been rewritten 5 times already, and the 20261007 rewrite caused
-- a production NULL-location bug (see 20261008 header). Instead, active pins are kept
-- fresh server-side by touch_active_pinned_locations() (called from cron before matching),
-- so the existing 5-minute pool gate keeps working with zero client GPS writes.
-- Small, stable functions (cleanup / visibility / nearby count / map cells) get an
-- explicit pinned-active exemption as defense-in-depth if a touch tick is ever missed.

-- ---------------------------------------------------------------------------
-- 1. Privacy cleanup must never delete an active pin.
--    (Same signature/default as 20260826000000.)
-- ---------------------------------------------------------------------------
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
  DELETE FROM public.user_locations
  WHERE updated_at < v_cutoff
    AND NOT (
      COALESCE(is_pinned, FALSE) AND pinned_expires_at > NOW()
    );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_old_user_locations(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_old_user_locations(int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Truly-visible: an active pin counts as a fresh location.
--    (Same shape as 20260826000000, only the location EXISTS gains an OR branch.)
-- ---------------------------------------------------------------------------
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
      AND (
        EXISTS (
          SELECT 1
          FROM public.user_locations ul
          WHERE ul.user_id = p_user_id
            AND ul.updated_at >= NOW() - INTERVAL '15 minutes'
        )
        OR EXISTS (
          SELECT 1
          FROM public.user_locations ul
          WHERE ul.user_id = p_user_id
            AND COALESCE(ul.is_pinned, FALSE)
            AND ul.pinned_expires_at > NOW()
        )
      )
    )
  FROM public.users u
  WHERE u.id = p_user_id
), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;

-- ---------------------------------------------------------------------------
-- 3. Nearby count: pinned candidates stay countable even if a touch is missed.
--    (Byte-identical to 20260813000000 except the 30-minute filter gains OR pin.)
-- ---------------------------------------------------------------------------
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
    earth_km CONSTANT double precision := 6371.0;
BEGIN
    -- Get current user's latest location
    SELECT latitude, longitude
    INTO user_lat, user_lon
    FROM public.user_locations
    WHERE user_id = p_user_id
    ORDER BY updated_at DESC
    LIMIT 1;

    -- If user has no location, return 0
    IF user_lat IS NULL OR user_lon IS NULL THEN
        RETURN 0;
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
          AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
                               AND user_lon + (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
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

GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision) TO anon;

-- ---------------------------------------------------------------------------
-- 4. Nearby map cells: same pinned exemption in the recency CTE.
--    (Byte-identical to 20260218012000 except the recency filter gains OR pin.)
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

-- ---------------------------------------------------------------------------
-- 5. Server-side freshness heartbeat for active pins.
--    Called from cron BEFORE continuous matching + cleanup. No client GPS involved:
--    coordinates are untouched, only updated_at is bumped so the 5-minute
--    matching-pool gate keeps seeing pinned users. Throttled to rows older than
--    4 minutes to avoid useless writes (each write fires the location trigger).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_active_pinned_locations()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_touched int := 0;
BEGIN
  UPDATE public.user_locations
  SET updated_at = NOW()
  WHERE COALESCE(is_pinned, FALSE)
    AND pinned_expires_at > NOW()
    AND updated_at < NOW() - INTERVAL '4 minutes';
  GET DIAGNOSTICS v_touched = ROW_COUNT;
  RETURN v_touched;
END;
$$;

GRANT EXECUTE ON FUNCTION public.touch_active_pinned_locations() TO service_role;
GRANT EXECUTE ON FUNCTION public.touch_active_pinned_locations() TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Auto-expire pins past their time. Cleared rows are marked stale (16 min)
--    so the user stays invisible until the next live GPS write arrives, instead
--    of briefly matching at the old pin. Called from cron (wired in step 2).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expire_pinned_locations()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired int := 0;
BEGIN
  UPDATE public.user_locations
  SET is_pinned = FALSE,
      pinned_expires_at = NULL,
      pinned_created_at = NULL,
      pinned_label = NULL,
      updated_at = NOW() - INTERVAL '16 minutes'
  WHERE COALESCE(is_pinned, FALSE)
    AND pinned_expires_at IS NOT NULL
    AND pinned_expires_at <= NOW();
  GET DIAGNOSTICS v_expired = ROW_COUNT;
  RETURN v_expired;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_pinned_locations() TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_pinned_locations() TO authenticated;
