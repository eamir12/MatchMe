-- Admin map: return locations of currently online or visible users
-- Used by the admin dashboard drilldown "View Map" button.
-- Excludes admin accounts.

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
  v_result jsonb;
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
    SELECT COALESCE(jsonb_build_object(
      'users', jsonb_agg(
        jsonb_build_object(
          'user_id', u.id,
          'user_name', COALESCE(u.name, 'User ' || substring(u.id::text, 1, 8)),
          'latitude', ul.latitude,
          'longitude', ul.longitude,
          'last_activity', ua.last_activity,
          'photo_url', (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1)
        )
      )
    ), jsonb_build_object('users', '[]'::jsonb))
    INTO v_result
    FROM public.user_activity ua
    JOIN public.users u ON u.id = ua.user_id
    JOIN public.user_locations ul ON ul.user_id = ua.user_id
    LEFT JOIN public.user_profiles up ON up.user_id = ua.user_id
    WHERE ua.is_online = true
      AND ua.last_activity > now() - interval '61 seconds'
      AND COALESCE(u.is_admin, false) = false
      AND ul.latitude IS NOT NULL
      AND ul.longitude IS NOT NULL;
  ELSE
    SELECT COALESCE(jsonb_build_object(
      'users', jsonb_agg(
        jsonb_build_object(
          'user_id', u.id,
          'user_name', COALESCE(u.name, 'User ' || substring(u.id::text, 1, 8)),
          'latitude', ul.latitude,
          'longitude', ul.longitude,
          'last_activity', ua.last_activity,
          'photo_url', (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1)
        )
      )
    ), jsonb_build_object('users', '[]'::jsonb))
    INTO v_result
    FROM public.user_activity ua
    JOIN public.users u ON u.id = ua.user_id
    JOIN public.user_locations ul ON ul.user_id = ua.user_id
    LEFT JOIN public.user_profiles up ON up.user_id = ua.user_id
    WHERE public.is_user_truly_visible(ua.user_id) = true
      AND COALESCE(u.is_admin, false) = false
      AND ul.latitude IS NOT NULL
      AND ul.longitude IS NOT NULL;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) TO authenticated;

COMMIT;
