-- Migration: Fix get_nearby_users_count accuracy and enable realtime for user_locations/user_session
-- Date: 2026-08-13
-- Purpose:
--   1) get_nearby_users_count now:
--      - Uses the canonical 61-second online window (was 10s, causing the nearby
--        count to drop users who heartbeat every ~25-30s but are still online).
--      - Uses the exact great-circle distance (was a bounding box, which counted
--        users up to ~1.41x the selected radius away in the box corners).
--      - Deduplicates to each user's LATEST location row (DISTINCT ON user_id).
--      - Uses the same 30-minute location freshness window as
--        get_visible_online_user_map_cells so the home screen and nearby map agree.
--   2) Enables Postgres Changes realtime on user_locations and user_session so the
--      dashboard stats provider and map screens refresh immediately when users
--      enter/leave the proximity range or register/update sessions.

-- 1. Rewrite get_nearby_users_count (double precision signature introduced in
--    20260626000000_fix_radius_precision.sql)
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
          AND ul.updated_at > NOW() - INTERVAL '30 minutes'
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

-- 2. Enable realtime on user_locations (drives nearby-count refreshes when users
--    enter/leave the proximity range) and user_session (drives the online world
--    map country markers). Both are idempotent guards.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_locations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_locations;
    RAISE NOTICE 'user_locations added to supabase_realtime publication';
  ELSE
    RAISE NOTICE 'user_locations already in supabase_realtime publication';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_session'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_session;
    RAISE NOTICE 'user_session added to supabase_realtime publication';
  ELSE
    RAISE NOTICE 'user_session already in supabase_realtime publication';
  END IF;
END $$;

-- Verify
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('user_locations', 'user_session');