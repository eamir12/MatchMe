-- Admin map: also report how many users have no location row.
--
-- Problem: the online map INNER-joins user_locations (a map needs
-- coordinates), so online users without any location row get no pin and the
-- map silently shows fewer users than the LIVE online card/drilldown. The
-- common case is an invisible user: the main app deliberately uploads no
-- location while invisible (privacy) yet still heartbeats, so they count as
-- online but are unpinnable.
--
-- Fix (additive only): also return the total count under the same filter plus
-- the difference, so the admin UI can render "1 of 2 users" and explain that
-- N users have no location yet. Old app versions ignore the extra keys.
--   online mode:  {users, total_online, without_location}
--   visible mode: {users, total_visible, without_location}
-- (visible mode's without_location is ~always 0 because truly-visible
-- requires a fresh location; it is returned anyway for symmetry.)

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_user_map_locations(p_mode text DEFAULT 'online')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_mode text;
  v_now timestamptz := now();
  v_result jsonb;
  v_total int;
  v_with int;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users WHERE id = auth.uid() AND is_admin = true
  ) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_mode := lower(btrim(COALESCE(p_mode, 'online')));
  IF v_mode NOT IN ('online', 'visible') THEN
    v_mode := 'online';
  END IF;

  IF v_mode = 'online' THEN
    -- Total online users under the same filter (team included, see 20262004).
    SELECT COALESCE(COUNT(DISTINCT ua.user_id), 0)::int INTO v_total
    FROM public.user_activity ua
    JOIN public.users u ON u.id = ua.user_id
    WHERE ua.is_online = true
      AND ua.last_activity > v_now - interval '61 seconds';

    -- Online users WITH a location row. The LATERAL subquery picks the
    -- latest location per user so duplicate location rows never duplicate pins.
    SELECT COALESCE(jsonb_build_object(
      'users', jsonb_agg(
        jsonb_build_object(
          'user_id', u.id,
          'user_name', COALESCE(u.name, 'User ' || substring(u.id::text, 1, 8)),
          'latitude', ul.latitude,
          'longitude', ul.longitude,
          'last_activity', ua.last_activity,
          'photo_url', CASE
            WHEN jsonb_typeof(up.photos) = 'array' THEN
              (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1)
            ELSE NULL
          END
        )
      )
    ), jsonb_build_object('users', '[]'::jsonb))
    INTO v_result
    FROM public.user_activity ua
    JOIN public.users u ON u.id = ua.user_id
    JOIN LATERAL (
      SELECT lat.latitude, lat.longitude
      FROM public.user_locations lat
      WHERE lat.user_id = ua.user_id
        AND lat.latitude IS NOT NULL
        AND lat.longitude IS NOT NULL
      ORDER BY lat.updated_at DESC NULLS LAST
      LIMIT 1
    ) ul ON true
    LEFT JOIN public.user_profiles up ON up.user_id = ua.user_id
    WHERE ua.is_online = true
      AND ua.last_activity > v_now - interval '61 seconds';

    v_with := COALESCE(jsonb_array_length(v_result -> 'users'), 0);
    v_result := v_result || jsonb_build_object(
      'total_online', v_total,
      'without_location', GREATEST(v_total - v_with, 0)
    );
  ELSE
    -- Total truly-visible users under the same filter (team included).
    SELECT COUNT(DISTINCT u.id)::int INTO v_total
    FROM public.users u
    WHERE public.is_user_truly_visible(u.id) = true;

    SELECT COALESCE(jsonb_build_object(
      'users', jsonb_agg(
        jsonb_build_object(
          'user_id', u.id,
          'user_name', COALESCE(u.name, 'User ' || substring(u.id::text, 1, 8)),
          'latitude', ul.latitude,
          'longitude', ul.longitude,
          'last_activity', ua.last_activity,
          'photo_url', CASE
            WHEN jsonb_typeof(up.photos) = 'array' THEN
              (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1)
            ELSE NULL
          END
        )
      )
    ), jsonb_build_object('users', '[]'::jsonb))
    INTO v_result
    FROM public.user_activity ua
    JOIN public.users u ON u.id = ua.user_id
    JOIN LATERAL (
      SELECT lat.latitude, lat.longitude
      FROM public.user_locations lat
      WHERE lat.user_id = ua.user_id
        AND lat.latitude IS NOT NULL
        AND lat.longitude IS NOT NULL
      ORDER BY lat.updated_at DESC NULLS LAST
      LIMIT 1
    ) ul ON true
    LEFT JOIN public.user_profiles up ON up.user_id = ua.user_id
    WHERE public.is_user_truly_visible(ua.user_id) = true;

    v_with := COALESCE(jsonb_array_length(v_result -> 'users'), 0);
    v_result := v_result || jsonb_build_object(
      'total_visible', v_total,
      'without_location', GREATEST(v_total - v_with, 0)
    );
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) TO authenticated;

COMMIT;
