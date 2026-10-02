-- Admin LIVE counts accuracy + consistency fix.
--
-- Problem: admin LIVE online/visible cards sometimes show fewer users than
-- expected (e.g. 1 instead of 2) and can disagree with their drilldowns/maps.
--
-- Root causes fixed here:
--  1. Stale legacy system_visibility_status values ('gps_problem',
--     'network_offline', 'offline', 'invisible_rules') are never written by
--     current code but still fail the `= 'visible'` check, permanently hiding
--     users who toggled visible ON. One-time data repair below resets them
--     for manually-visible users.
--  2. admin_get_realtime_user_counts used two separate NOW() calls and
--     COUNT(*) without DISTINCT, so the two cards could disagree by ms and
--     diverge from drilldown totals if duplicate rows ever exist.
--  3. admin_get_dashboard_drilldown LIVE branches missed DISTINCT, used an
--     unsafe photo extraction (a single malformed photos value aborts the
--     whole RPC), and LEFT JOINed user_locations directly (duplicate location
--     rows duplicate drilldown rows). Fixed in 20262003 with DISTINCT,
--     jsonb_typeof guard, and LATERAL latest-location-per-user.
--  4. admin_get_user_map_locations JOINed user_locations directly (duplicates
--     => duplicate pins) with the same unsafe photo extraction. Fixed below
--     with LATERAL latest-location-per-user + safe photo.
--  5. Missing unique guard on user_locations(user_id) allowed duplicates
--     (user_activity already got one in 20260815). Dedupe + unique index.
--
-- Windows are intentionally unchanged (online 61s, visible location 15m) to
-- stay consistent with is_user_truly_visible / matching / nearby logic.

BEGIN;

-- ============================================================
-- 0. One-time data repair: dead visibility statuses
-- ============================================================
UPDATE public.users
SET system_visibility_status = 'visible'
WHERE COALESCE(user_visibility_setting, false) = true
  AND COALESCE(system_visibility_status, 'visible') IN (
    'gps_problem', 'network_offline', 'offline', 'invisible_rules'
  );

-- ============================================================
-- 1. Dedupe user_locations + unique guard (mirror 20260815 activity fix)
-- ============================================================
WITH ranked AS (
  SELECT
    ul.ctid,
    ROW_NUMBER() OVER (
      PARTITION BY ul.user_id
      ORDER BY ul.updated_at DESC NULLS LAST,
               ul.ctid DESC
    ) AS rn
  FROM public.user_locations ul
)
DELETE FROM public.user_locations ul
USING ranked r
WHERE ul.ctid = r.ctid
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_locations_user_id_unique
ON public.user_locations (user_id);

-- Ensure the activity unique guard exists (idempotent if 20260815 applied)
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_activity_user_id_unique
ON public.user_activity (user_id);

-- ============================================================
-- 2. admin_get_realtime_user_counts: single snapshot, DISTINCT, generated_at
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

  -- Currently online (heartbeat within 61s), excluding admin accounts.
  -- Single v_now snapshot so both cards agree with each other and with the
  -- online_users_live drilldown base below.
  SELECT COALESCE(COUNT(DISTINCT ua.user_id), 0)::int INTO v_online
  FROM public.user_activity ua
  JOIN public.users u ON u.id = ua.user_id
  WHERE ua.is_online = true
    AND ua.last_activity > v_now - interval '61 seconds'
    AND COALESCE(u.is_admin, false) = false;

  -- Currently truly visible (online + visibility settings + fresh location),
  -- excluding admin accounts. Same definition as the visible_users_live
  -- drilldown base and admin map (visible mode).
  SELECT COUNT(DISTINCT u.id)::int INTO v_visible
  FROM public.users u
  WHERE public.is_user_truly_visible(u.id) = true
    AND COALESCE(u.is_admin, false) = false;

  RETURN jsonb_build_object(
    'online_users', v_online,
    'visible_users', v_visible,
    'generated_at', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_realtime_user_counts() TO authenticated;

-- ============================================================
-- 3. admin_get_user_map_locations: dedupe locations, safe photo, single NOW()
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
      AND ua.last_activity > v_now - interval '61 seconds'
      AND COALESCE(u.is_admin, false) = false;
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
    WHERE public.is_user_truly_visible(ua.user_id) = true
      AND COALESCE(u.is_admin, false) = false;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) TO authenticated;

COMMIT;
