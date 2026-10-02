-- Admin LIVE counts: include admin accounts.
--
-- Problem: the LIVE online/visible cards (and their drilldowns + map)
-- excluded every user with is_admin = true. An admin who also uses the main
-- app day-to-day (e.g. Eran, logged into MatchMe AND the admin app) is
-- online and visible in MatchMe but invisible in the admin LIVE section:
-- with Eran (admin, online+visible) and John (non-admin, online+invisible)
-- the cards showed 1 online / 0 visible instead of the expected 2 / 1.
--
-- Policy change (LIVE section only): LIVE means "who is on the network right
-- now", team members included. This also aligns the admin LIVE online count
-- with the main app's home online counter (get_online_others_count), which
-- never excluded admins.
-- This is safe from self-inflation: the admin app only READS presence
-- (realtime subscriptions); it never writes user_activity / user_session, so
-- monitoring never marks anyone online.
-- Windowed engagement stats (admin_get_dashboard_stats 24h/7d) intentionally
-- still exclude admins so product metrics stay clean.
--
-- Changes:
--  1. admin_get_realtime_user_counts(): drop the is_admin filter (both cards).
--  2. admin_get_user_map_locations(): drop the is_admin filter (both modes).
--  3. admin_get_dashboard_drilldown() LIVE branches (online_users_live,
--     visible_users_live): drop the is_admin filter — see migration
--     20262005 (full function body must be replaced wholesale).

BEGIN;

-- ============================================================
-- 1. admin_get_realtime_user_counts: count everyone online/visible
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_get_realtime_user_counts()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_now timestamptz := now();
  v_online int;
  v_visible int;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users WHERE id = auth.uid() AND is_admin = true
  ) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  -- Currently online (heartbeat within 61s), team members included.
  -- Single v_now snapshot so both cards agree with each other and with the
  -- online_users_live drilldown base. JOIN to users excludes orphan activity
  -- rows left behind by deleted accounts.
  SELECT COALESCE(COUNT(DISTINCT ua.user_id), 0)::int INTO v_online
  FROM public.user_activity ua
  JOIN public.users u ON u.id = ua.user_id
  WHERE ua.is_online = true
    AND ua.last_activity > v_now - interval '61 seconds';

  -- Currently truly visible (online + visibility settings + fresh location),
  -- team members included. Same definition as the visible_users_live
  -- drilldown base and admin map (visible mode).
  SELECT COUNT(DISTINCT u.id)::int INTO v_visible
  FROM public.users u
  WHERE public.is_user_truly_visible(u.id) = true;

  RETURN jsonb_build_object(
    'online_users', v_online,
    'visible_users', v_visible,
    'generated_at', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_realtime_user_counts() TO authenticated;

-- ============================================================
-- 2. admin_get_user_map_locations: show everyone (both modes)
-- ============================================================
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
    -- All online users WITH a location row. The LATERAL subquery picks the
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
  ELSE
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
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) TO authenticated;

COMMIT;
