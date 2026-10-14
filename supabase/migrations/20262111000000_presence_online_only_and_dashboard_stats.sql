-- Migration: Presence semantics alignment + single-call dashboard stats RPC
-- Date: 2026-10-14
--
-- Decisions implemented here:
--   1. "Online" means a live heartbeat only. The pinned-location OR branch is
--      REMOVED from every online count (user app + admin LIVE). Pin-only
--      users are still fully matchable (matching/nearby/visibility keep the
--      pin branch untouched in 20262085/20262086/20262090) — they just are
--      not advertised as "online right now". Rationale: device heartbeats are
--      best-effort (WorkManager chain, killed by force-stop/OEM/Doze; iOS
--      suspends), so a pin can outlive the heartbeat by days — counting
--      pin-only users as online is exactly the stale-"online" bug class
--      reported with long-pinned accounts.
--   2. Completed profiles only, EVERYWHERE. The admin LIVE carve-out that
--      counted team members with incomplete profiles (20262004000000 /
--      20262005000000) is removed: admin LIVE surfaces now use the exact
--      same predicate as the user app.
--   3. One shared predicate: online_presence_user_ids() — a single index
--      scan over the new partial index on user_activity (is_online = true).
--   4. Country comes from user_locations.country_code (server-side PostGIS
--      derivation, 20262110), falling back to user_session.country, then an
--      explicit 'UNKNOWN' bucket so header totals always equal the sum of
--      the country markers.
--   5. NEW get_online_dashboard_stats(p_user_id): online-others count +
--      per-country counts + self country + self completeness + match radius
--      from ONE snapshot in ONE round trip. The MatchMe app no longer needs
--      the config Edge Function, a users.single() query, or the separate
--      country RPC on the critical path, and the online number is not held
--      back by the nearby-count query or by unit resolution.
--   6. Matching / nearby / visibility primitives are intentionally NOT
--      changed: perform_continuous_user_matching, find_nearby_users,
--      get_potential_matches*, is_user_truly_visible keep the pin branch.
--   7. Drilldown (admin_get_dashboard_drilldown): online_users_live uses the
--      shared helper; online_users_live and visible_users_live rows now
--      expose is_pinned so the admin UI can badge pinned users.
--
-- Indexes added: partial on user_activity for the heartbeat scan, covering
-- index on active user_session rows for the country fallback.

BEGIN;

-- ---------------------------------------------------------------------------
-- (1) Shared online-presence predicate: heartbeat within the window AND a
--     completed profile. NO pin branch. One partial index serves it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.online_presence_user_ids(
  p_recent_seconds integer DEFAULT 61
)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ua.user_id
  FROM public.user_activity ua
  JOIN public.users u ON u.id = ua.user_id
  WHERE ua.is_online = true
    AND ua.last_activity > NOW() - make_interval(
      secs => GREATEST(LEAST(COALESCE(p_recent_seconds, 61), 3600), 5)
    )
    AND COALESCE(u.is_profile_complete, false) = true;
$$;

GRANT EXECUTE ON FUNCTION public.online_presence_user_ids(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.online_presence_user_ids(integer) TO service_role;

COMMENT ON FUNCTION public.online_presence_user_ids(integer) IS
  'Shared presence predicate for ALL online counts (app + admin): heartbeat within the window AND completed profile. Pinned-only users are intentionally excluded (they remain matchable via the pin).';

-- ---------------------------------------------------------------------------
-- (2) Home-screen online counter (others only; the client adds self when the
--     own profile is complete).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_online_others_count(p_user_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM public.online_presence_user_ids(61) op
  WHERE op <> p_user_id;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO anon;

-- ---------------------------------------------------------------------------
-- (3) Generic online counters.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_online_users_count(p_user_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM public.online_presence_user_ids(61);
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO service_role;

COMMENT ON FUNCTION public.get_online_users_count IS
  'Returns the number of distinct users currently online with completed profiles; prevents same-user double counting from stale/duplicate rows.';

CREATE OR REPLACE FUNCTION public.get_online_users_count_excluding_self(p_user_id UUID)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM public.online_presence_user_ids(61) op
  JOIN public.users u ON u.id = op
  WHERE op <> p_user_id
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible';
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;

-- ---------------------------------------------------------------------------
-- (4)/(5) Online counts by country. Country resolution:
--     user_locations.country_code -> user_session.country -> 'UNKNOWN'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_online_user_counts_by_country(
  p_recent_seconds integer DEFAULT 61
)
RETURNS TABLE (
  country text,
  user_count integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seconds integer;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_seconds := GREATEST(LEAST(COALESCE(p_recent_seconds, 61), 3600), 5);

  RETURN QUERY
  WITH online AS (
    SELECT op AS user_id FROM public.online_presence_user_ids(v_seconds) op
  ),
  latest_location AS (
    SELECT DISTINCT ON (ul.user_id)
      ul.user_id,
      NULLIF(btrim(ul.country_code), '') AS country_code
    FROM public.user_locations ul
    WHERE ul.country_code IS NOT NULL
    ORDER BY ul.user_id, ul.updated_at DESC NULLS LAST
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
  )
  SELECT
    COALESCE(ll.country_code, ls.country, 'UNKNOWN') AS country,
    COUNT(*)::integer AS user_count
  FROM online o
  LEFT JOIN latest_location ll ON ll.user_id = o.user_id
  LEFT JOIN latest_session ls ON ls.user_id = o.user_id
  GROUP BY COALESCE(ll.country_code, ls.country, 'UNKNOWN')
  ORDER BY user_count DESC, country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;

COMMENT ON FUNCTION public.get_online_user_counts_by_country(integer) IS
  'Online user counts grouped by country (heartbeat-only, completed profiles). Country is derived server-side from coordinates (user_locations.country_code) with session fallback and an explicit UNKNOWN bucket, so the buckets always sum to the online total.';

CREATE OR REPLACE FUNCTION public.get_online_user_counts_by_country_excluding_self(
  p_user_id uuid,
  p_recent_seconds integer DEFAULT 61
)
RETURNS TABLE (
  country text,
  user_count integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seconds integer;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_seconds := GREATEST(LEAST(COALESCE(p_recent_seconds, 61), 3600), 5);

  RETURN QUERY
  WITH online AS (
    SELECT op AS user_id
    FROM public.online_presence_user_ids(v_seconds) op
    WHERE p_user_id IS NULL OR op <> p_user_id
  ),
  latest_location AS (
    SELECT DISTINCT ON (ul.user_id)
      ul.user_id,
      NULLIF(btrim(ul.country_code), '') AS country_code
    FROM public.user_locations ul
    WHERE ul.country_code IS NOT NULL
    ORDER BY ul.user_id, ul.updated_at DESC NULLS LAST
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
  )
  SELECT
    COALESCE(ll.country_code, ls.country, 'UNKNOWN') AS country,
    COUNT(*)::integer AS user_count
  FROM online o
  LEFT JOIN latest_location ll ON ll.user_id = o.user_id
  LEFT JOIN latest_session ls ON ls.user_id = o.user_id
  GROUP BY COALESCE(ll.country_code, ls.country, 'UNKNOWN')
  ORDER BY user_count DESC, country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country_excluding_self(uuid, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- (6) NEW: one round trip for the home card + online world map.
--     Returns online-others count, per-country counts, self country, self
--     profile completeness and the user's match radius from ONE snapshot.
--     Client displays online = online_others + (self_is_complete ? 1 : 0),
--     preserving the "signed-in user is online by definition" rule while
--     never counting incomplete profiles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_online_dashboard_stats(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := now();
  v_others integer;
  v_countries jsonb;
  v_self_complete boolean := false;
  v_self_online boolean := false;
  v_self_country text;
  v_radius integer;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT COALESCE(COUNT(*), 0)::integer
  INTO v_others
  FROM public.online_presence_user_ids(61) op
  WHERE op <> p_user_id;

  WITH online AS (
    SELECT op AS user_id FROM public.online_presence_user_ids(61) op
    WHERE op <> p_user_id
  ),
  latest_location AS (
    SELECT DISTINCT ON (ul.user_id)
      ul.user_id,
      NULLIF(btrim(ul.country_code), '') AS country_code
    FROM public.user_locations ul
    WHERE ul.country_code IS NOT NULL
    ORDER BY ul.user_id, ul.updated_at DESC NULLS LAST
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
  ),
  grouped AS (
    SELECT
      COALESCE(ll.country_code, ls.country, 'UNKNOWN') AS country,
      COUNT(*)::integer AS user_count
    FROM online o
    LEFT JOIN latest_location ll ON ll.user_id = o.user_id
    LEFT JOIN latest_session ls ON ls.user_id = o.user_id
    GROUP BY COALESCE(ll.country_code, ls.country, 'UNKNOWN')
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('country', g.country, 'user_count', g.user_count)
      ORDER BY g.user_count DESC, g.country ASC
    ),
    '[]'::jsonb
  )
  INTO v_countries
  FROM grouped g;

  SELECT
    COALESCE(u.is_profile_complete, false),
    u.match_radius_default
  INTO v_self_complete, v_radius
  FROM public.users u
  WHERE u.id = p_user_id;

  SELECT EXISTS (
    SELECT 1
    FROM public.user_activity ua
    WHERE ua.user_id = p_user_id
      AND ua.is_online = true
      AND ua.last_activity > v_now - interval '61 seconds'
  )
  INTO v_self_online;

  WITH latest_location AS (
    SELECT NULLIF(btrim(ul.country_code), '') AS country_code
    FROM public.user_locations ul
    WHERE ul.user_id = p_user_id
      AND ul.country_code IS NOT NULL
    ORDER BY ul.updated_at DESC NULLS LAST
    LIMIT 1
  ),
  latest_session AS (
    SELECT NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.user_id = p_user_id
      AND us.revoked = false
    ORDER BY
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
    LIMIT 1
  )
  SELECT COALESCE(ll.country_code, ls.country)
  INTO v_self_country
  FROM latest_location ll
  FULL JOIN latest_session ls ON true;

  RETURN jsonb_build_object(
    'online_others', COALESCE(v_others, 0),
    'self_is_complete', COALESCE(v_self_complete, false),
    'self_online', COALESCE(v_self_online, false),
    'self_country', v_self_country,
    'countries', COALESCE(v_countries, '[]'::jsonb),
    'match_radius_default', v_radius,
    'generated_at', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_dashboard_stats(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_online_dashboard_stats(uuid) IS
  'Single-call dashboard snapshot: online-others count, per-country counts, self country, self profile completeness and match radius from one NOW() snapshot. Online = heartbeat-only, completed profiles, pinned-only users excluded (still matchable via pin).';

-- ---------------------------------------------------------------------------
-- (7) Admin LIVE online card: same predicate as the app (no pin, no admin
--     incomplete-profile carve-out).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_realtime_user_counts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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

  -- Currently online: heartbeat within 61s + completed profile, identical
  -- predicate to the user app (20262111 removed both the pin branch and the
  -- admin incomplete-profile carve-out).
  SELECT COALESCE(COUNT(*), 0)::int INTO v_online
  FROM public.online_presence_user_ids(61) op;

  -- Currently truly visible (online + visibility settings + fresh location +
  -- completed profile via is_user_truly_visible), same definition as the
  -- visible_users_live drilldown base and admin map (visible mode).
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

-- ---------------------------------------------------------------------------
-- (8) Admin map: online mode uses the shared heartbeat-only predicate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_user_map_locations(p_mode text DEFAULT 'online')
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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
    -- Total online users: heartbeat-only + completed profile (20262111:
    -- pin branch and admin carve-out removed, same as the user app).
    SELECT COALESCE(COUNT(*), 0)::int INTO v_total
    FROM public.online_presence_user_ids(61) op;

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
          'is_pinned', EXISTS (
            SELECT 1 FROM public.user_locations pin_ul
            WHERE pin_ul.user_id = u.id
              AND COALESCE(pin_ul.is_pinned, false)
              AND pin_ul.pinned_expires_at > v_now
          ),
          'photo_url', CASE
            WHEN jsonb_typeof(up.photos) = 'array' THEN
              (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1)
            ELSE NULL
          END
        )
      )
    ), jsonb_build_object('users', '[]'::jsonb))
    INTO v_result
    FROM public.online_presence_user_ids(61) op
    JOIN public.users u ON u.id = op
    JOIN public.user_activity ua ON ua.user_id = op
    JOIN LATERAL (
      SELECT lat.latitude, lat.longitude
      FROM public.user_locations lat
      WHERE lat.user_id = op
        AND lat.latitude IS NOT NULL
        AND lat.longitude IS NOT NULL
      ORDER BY lat.updated_at DESC NULLS LAST
      LIMIT 1
    ) ul ON true
    LEFT JOIN public.user_profiles up ON up.user_id = op;

    v_with := COALESCE(jsonb_array_length(v_result -> 'users'), 0);
    v_result := v_result || jsonb_build_object(
      'total_online', v_total,
      'without_location', GREATEST(v_total - v_with, 0)
    );
  ELSE
    -- Total truly-visible users (is_user_truly_visible keeps the pin branch:
    -- a pinned user IS on the map — "visible", not "online").
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
          'is_pinned', EXISTS (
            SELECT 1 FROM public.user_locations pin_ul
            WHERE pin_ul.user_id = u.id
              AND COALESCE(pin_ul.is_pinned, false)
              AND pin_ul.pinned_expires_at > v_now
          ),
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

-- ---------------------------------------------------------------------------
-- (9) Indexes for the hot paths
-- ---------------------------------------------------------------------------
-- Heartbeat scan: every online count is now one partial index scan.
CREATE INDEX IF NOT EXISTS idx_user_activity_online_recent
  ON public.user_activity (last_activity)
  WHERE is_online = true;

-- Country fallback: active sessions per user without scanning revoked rows.
CREATE INDEX IF NOT EXISTS idx_user_session_active_user_country
  ON public.user_session (user_id)
  INCLUDE (country)
  WHERE revoked = false;


-- ---------------------------------------------------------------------------
-- (10) admin_get_dashboard_drilldown: latest full definition (from
--      20262098000000) with the online_users_live branch moved to the shared
--      heartbeat-only helper, and is_pinned exposed on online/visible LIVE
--      rows so the admin UI can badge pinned users.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_get_dashboard_drilldown(
  p_window text DEFAULT '24h',
  p_metric text DEFAULT NULL,
  p_param text DEFAULT NULL,
  p_limit integer DEFAULT 200,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_window text;
  v_metric text;
  v_param text;
  v_p1 text;
  v_p2 text;
  v_p3 text;
  v_start timestamptz;
  v_limit int;
  v_offset int;
  v_fetch int;
  v_result jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_window := COALESCE(NULLIF(TRIM(p_window), ''), '24h');
  IF v_window NOT IN ('24h', '7d') THEN
    v_window := '24h';
  END IF;

  v_metric := COALESCE(NULLIF(TRIM(p_metric), ''), '');
  v_param := NULLIF(TRIM(COALESCE(p_param, '')), '');
  v_p1 := NULLIF(TRIM(split_part(COALESCE(v_param, ''), '|', 1)), '');
  v_p2 := NULLIF(TRIM(split_part(COALESCE(v_param, ''), '|', 2)), '');
  v_p3 := NULLIF(TRIM(split_part(COALESCE(v_param, ''), '|', 3)), '');

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 500), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_fetch := v_limit + 1;

  IF v_window = '24h' THEN
    v_start := date_trunc('hour', now() - interval '23 hours');
  ELSE
    v_start := date_trunc('day', now() - interval '6 days');
  END IF;

  IF v_metric = 'online_users_live' THEN
    -- LIVE: heartbeat within 61s + completed profile, identical predicate to
    -- the user app (20262111: pin-only users and incomplete admin profiles
    -- no longer count as online; pinned users remain matchable and appear
    -- under visible_users_live with is_pinned = true).
    WITH base AS (
      SELECT op AS user_id
      FROM public.online_presence_user_ids(61) op
    ),
    total AS (
      SELECT COUNT(*)::int AS total_count FROM base
    ),
    rows AS (
      SELECT
        b.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(b.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at,
        ul.latitude,
        ul.longitude,
        CASE WHEN jsonb_typeof(up.photos) = 'array' THEN (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1) ELSE NULL END AS photo_url,
        EXISTS (
          SELECT 1 FROM public.user_locations pin_ul
          WHERE pin_ul.user_id = b.user_id
            AND COALESCE(pin_ul.is_pinned, false)
            AND pin_ul.pinned_expires_at > now()
        ) AS is_pinned
      FROM base b
      JOIN public.users u ON u.id = b.user_id
      JOIN public.user_activity ua ON ua.user_id = b.user_id
      LEFT JOIN public.user_profiles up ON up.user_id = b.user_id
      LEFT JOIN LATERAL (SELECT lat.latitude, lat.longitude FROM public.user_locations lat WHERE lat.user_id = b.user_id ORDER BY lat.updated_at DESC NULLS LAST LIMIT 1) ul ON true
      ORDER BY ua.last_activity DESC, b.user_id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'total_count', (SELECT total_count FROM total),
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'visible_users_live' THEN
    -- LIVE: only users currently visible right now (online + visibility settings), including admins (see 20262095)
    WITH base AS (
      SELECT DISTINCT ua.user_id
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE public.is_user_truly_visible(ua.user_id) = true
    ),
    total AS (
      SELECT COUNT(*)::int AS total_count FROM base
    ),
    rows AS (
      SELECT
        b.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(b.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at,
        ul.latitude,
        ul.longitude,
        CASE WHEN jsonb_typeof(up.photos) = 'array' THEN (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1) ELSE NULL END AS photo_url,
        EXISTS (
          SELECT 1 FROM public.user_locations pin_ul
          WHERE pin_ul.user_id = b.user_id
            AND COALESCE(pin_ul.is_pinned, false)
            AND pin_ul.pinned_expires_at > now()
        ) AS is_pinned
      FROM base b
      JOIN public.users u ON u.id = b.user_id
      JOIN public.user_activity ua ON ua.user_id = b.user_id
      LEFT JOIN public.user_profiles up ON up.user_id = b.user_id
      LEFT JOIN LATERAL (SELECT lat.latitude, lat.longitude FROM public.user_locations lat WHERE lat.user_id = b.user_id ORDER BY lat.updated_at DESC NULLS LAST LIMIT 1) ul ON true
      ORDER BY ua.last_activity DESC, b.user_id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'total_count', (SELECT total_count FROM total),
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'online_users' THEN
    -- Cumulative: show all users who were active during the window, including admins (see 20262095)
    WITH rows AS (
      SELECT
        ua.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE ua.last_activity >= v_start
        AND COALESCE(u.is_profile_complete, false) = true
      ORDER BY ua.last_activity DESC, ua.user_id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'visible_users' THEN
    -- Cumulative: users who were ACTUALLY visible at some point during the
    -- window (see 20262096) -- same components as is_user_truly_visible()
    -- with the freshness bounds widened to the window, including admins.
    -- Driven from users so pinned-only users (no heartbeat in the window)
    -- are listed too.
    WITH rows AS (
      SELECT
        u.id AS user_id,
        COALESCE(u.name, 'User ' || substring(u.id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.users u
      LEFT JOIN LATERAL (
        SELECT la.last_activity
        FROM public.user_activity la
        WHERE la.user_id = u.id
        ORDER BY la.last_activity DESC NULLS LAST
        LIMIT 1
      ) ua ON true
      WHERE COALESCE(u.is_profile_complete, false) = true
        AND EXISTS (
          -- Effective visibility settings were "visible" at some point
          -- overlapping the window (state history, see 20262098): the table
          -- records every visible<->hidden transition, so a user who toggled
          -- visibility off mid-window stays counted until the window slides
          -- past the toggle time.
          SELECT 1
          FROM (
            SELECT h.visible,
                   LEAD(h.changed_at) OVER (ORDER BY h.changed_at, h.id)
                     AS next_changed_at
            FROM public.user_visibility_state_history h
            WHERE h.user_id = u.id
          ) s
          WHERE s.visible = true
            AND COALESCE(s.next_changed_at, 'infinity'::timestamptz) > v_start
        )
        AND (
          EXISTS (
            SELECT 1 FROM public.user_activity a2
            WHERE a2.user_id = u.id
              AND a2.last_activity >= v_start
          )
          OR EXISTS (
            SELECT 1 FROM public.user_locations ulp
            WHERE ulp.user_id = u.id
              AND COALESCE(ulp.is_pinned, false)
              AND ulp.pinned_expires_at > v_start
          )
        )
        AND (
          EXISTS (
            SELECT 1 FROM public.user_locations ul
            WHERE ul.user_id = u.id
              AND ul.updated_at >= v_start
          )
          OR EXISTS (
            SELECT 1 FROM public.user_locations ulp
            WHERE ulp.user_id = u.id
              AND COALESCE(ulp.is_pinned, false)
              AND ulp.pinned_expires_at > v_start
          )
        )
      ORDER BY ua.last_activity DESC NULLS LAST, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'new_users' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        u.created_at AS created_at
      FROM public.users u
      WHERE u.created_at >= v_start
        AND COALESCE(u.is_profile_complete, false) = true
      ORDER BY u.created_at DESC, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'messages_sent' THEN
    WITH rows AS (
      SELECT
        cm.sender_id AS user_id,
        u.name AS user_name,
        COUNT(*)::int AS messages
      FROM public.chat_messages cm
      LEFT JOIN public.users u ON u.id = cm.sender_id
      WHERE cm.created_at >= v_start
      GROUP BY cm.sender_id, u.name
      ORDER BY COUNT(*) DESC, cm.sender_id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'matches_created' THEN
    WITH rows AS (
      SELECT
        m.id AS match_id,
        m.user1_id,
        u1.name AS user1_name,
        m.user2_id,
        u2.name AS user2_name,
        m.created_at AS matched_at,
        m.matched_intent,
        to_jsonb(
          array(
            SELECT x
            FROM unnest(
              array[
                CASE WHEN m.match_type = 'proximity' THEN 'proximity' END,
                CASE WHEN m.match_type = 'event' THEN 'event' END,
                'shared_intent',
                CASE WHEN m.match_type IN ('proximity', 'event') THEN 'shared_interest' END
              ]::text[]
            ) AS t(x)
            WHERE x IS NOT NULL
          )
        ) AS basis,
        m.event_id,
        e.event_name
      FROM public.matches m
      LEFT JOIN public.users u1 ON u1.id = m.user1_id
      LEFT JOIN public.users u2 ON u2.id = m.user2_id
      LEFT JOIN public.events e ON e.id = m.event_id
      WHERE m.created_at >= v_start
      ORDER BY m.created_at DESC, m.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'active_matches' THEN
    WITH recent_match_ids AS (
      SELECT
        c.match_id,
        MAX(COALESCE(c.last_message_at, c.updated_at)) AS last_activity_at
      FROM public.chats c
      WHERE COALESCE(c.last_message_at, c.updated_at) >= v_start
      GROUP BY c.match_id
    ),
    rows AS (
      SELECT
        m.id AS match_id,
        m.user1_id,
        u1.name AS user1_name,
        m.user2_id,
        u2.name AS user2_name,
        m.created_at AS matched_at,
        r.last_activity_at,
        m.matched_intent,
        to_jsonb(
          array(
            SELECT x
            FROM unnest(
              array[
                CASE WHEN m.match_type = 'proximity' THEN 'proximity' END,
                CASE WHEN m.match_type = 'event' THEN 'event' END,
                'shared_intent',
                CASE WHEN m.match_type IN ('proximity', 'event') THEN 'shared_interest' END
              ]::text[]
            ) AS t(x)
            WHERE x IS NOT NULL
          )
        ) AS basis,
        m.event_id,
        e.event_name
      FROM recent_match_ids r
      JOIN public.matches m ON m.id = r.match_id
      LEFT JOIN public.users u1 ON u1.id = m.user1_id
      LEFT JOIN public.users u2 ON u2.id = m.user2_id
      LEFT JOIN public.events e ON e.id = m.event_id
      ORDER BY r.last_activity_at DESC, m.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'verification_pending' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        to_char(u.verification_submitted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS verification_submitted_at
      FROM public.users u
      WHERE u.verification_status = 'pending'
      ORDER BY u.verification_submitted_at DESC NULLS LAST, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'verification_analyzing' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        to_char(u.verification_submitted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS verification_submitted_at
      FROM public.users u
      WHERE u.verification_status = 'analyzing'
      ORDER BY u.verification_submitted_at DESC NULLS LAST, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'profile_edits_pending' THEN
    WITH rows AS (
      SELECT
        r.user_id,
        u.name AS user_name,
        to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
      FROM public.profile_edit_requests r
      LEFT JOIN public.users u ON u.id = r.user_id
      WHERE r.status = 'pending'
      ORDER BY r.created_at DESC, r.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'broadcasts_draft' THEN
    WITH rows AS (
      SELECT
        b.title,
        b.status,
        to_char(b.scheduled_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS scheduled_at,
        to_char(b.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
      FROM public.admin_broadcasts b
      WHERE b.status = 'draft'
      ORDER BY b.updated_at DESC NULLS LAST, b.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'broadcasts_scheduled' THEN
    WITH rows AS (
      SELECT
        b.title,
        b.status,
        to_char(b.scheduled_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS scheduled_at,
        to_char(b.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
      FROM public.admin_broadcasts b
      WHERE b.status = 'scheduled'
      ORDER BY b.scheduled_at DESC NULLS LAST, b.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'notifications_pending' THEN
    WITH rows AS (
      SELECT
        u.name AS user_name,
        n.title,
        n.status,
        n.attempts,
        to_char(n.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
      FROM public.notification_queue n
      LEFT JOIN public.users u ON u.id = n.user_id
      WHERE n.status = 'pending'
      ORDER BY n.created_at DESC, n.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'notifications_failed' THEN
    WITH rows AS (
      SELECT
        u.name AS user_name,
        n.title,
        n.status,
        n.attempts,
        n.failure_reason,
        to_char(n.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
      FROM public.notification_queue n
      LEFT JOIN public.users u ON u.id = n.user_id
      WHERE n.status = 'failed'
      ORDER BY n.created_at DESC, n.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'paid_active_users' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        u.subscription_tier,
        COALESCE(
          (
            SELECT jsonb_object_agg(currency, total_amount)
            FROM (
              SELECT
                COALESCE(
                  NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
                  NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
                  'usd'
                ) AS currency,
                SUM(
                  CASE
                    WHEN sq.purchase_metadata ? 'amount_cents'
                         AND (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
                    THEN (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
                    WHEN sq.purchase_metadata ? 'amount'
                         AND (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    THEN (sq.purchase_metadata ->> 'amount')::numeric
                    ELSE 0
                  END
                ) AS total_amount
              FROM public.user_subscription_queue sq
              WHERE sq.user_id = u.id
                AND COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
                AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
              GROUP BY 1
            ) s
          ),
          '{}'::jsonb
        ) AS earnings,
        to_char(u.subscription_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS subscription_expires_at
      FROM public.users u
      WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
        AND u.subscription_expires_at IS NOT NULL
        AND u.subscription_expires_at > now()
      ORDER BY u.subscription_expires_at DESC, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'paid_expiring_7d' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        u.subscription_tier,
        COALESCE(
          (
            SELECT jsonb_object_agg(currency, total_amount)
            FROM (
              SELECT
                COALESCE(
                  NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
                  NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
                  'usd'
                ) AS currency,
                SUM(
                  CASE
                    WHEN sq.purchase_metadata ? 'amount_cents'
                         AND (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
                    THEN (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
                    WHEN sq.purchase_metadata ? 'amount'
                         AND (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    THEN (sq.purchase_metadata ->> 'amount')::numeric
                    ELSE 0
                  END
                ) AS total_amount
              FROM public.user_subscription_queue sq
              WHERE sq.user_id = u.id
                AND COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
                AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
              GROUP BY 1
            ) s
          ),
          '{}'::jsonb
        ) AS earnings,
        to_char(u.subscription_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS subscription_expires_at
      FROM public.users u
      WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
        AND u.subscription_expires_at IS NOT NULL
        AND u.subscription_expires_at > now()
        AND u.subscription_expires_at <= now() + interval '7 days'
      ORDER BY u.subscription_expires_at DESC, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'paid_by_tier' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') AS subscription_tier,
        COALESCE(
          (
            SELECT jsonb_object_agg(currency, total_amount)
            FROM (
              SELECT
                COALESCE(
                  NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
                  NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
                  'usd'
                ) AS currency,
                SUM(
                  CASE
                    WHEN sq.purchase_metadata ? 'amount_cents'
                         AND (sq.purchase_metadata ->> 'amount_cents') ~ '^-?[0-9]+$'
                    THEN (sq.purchase_metadata ->> 'amount_cents')::numeric / 100
                    WHEN sq.purchase_metadata ? 'amount'
                         AND (sq.purchase_metadata ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    THEN (sq.purchase_metadata ->> 'amount')::numeric
                    ELSE 0
                  END
                ) AS total_amount
              FROM public.user_subscription_queue sq
              WHERE sq.user_id = u.id
                AND COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
                AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
              GROUP BY 1
            ) s
          ),
          '{}'::jsonb
        ) AS earnings,
        to_char(u.subscription_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS subscription_expires_at
      FROM public.users u
      WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
        AND u.subscription_expires_at IS NOT NULL
        AND u.subscription_expires_at > now()
        AND (v_param IS NULL OR COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') = v_param)
      ORDER BY u.subscription_expires_at DESC, u.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'param', v_param,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'edge_function_usage' THEN
    WITH rows AS (
      SELECT
        e.function_name,
        to_char(e.invoked_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS invoked_at,
        e.success,
        e.http_status,
        e.duration_ms,
        e.error_type,
        e.error_message,
        e.ai_used,
        e.ai_provider,
        e.ai_model,
        e.ai_task
      FROM public.edge_function_invocations e
      WHERE e.invoked_at >= v_start
        AND (v_param IS NULL OR e.function_name = v_param)
      ORDER BY e.invoked_at DESC, e.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'param', v_param,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSIF v_metric = 'ai_usage' THEN
    WITH rows AS (
      SELECT
        to_char(e.invoked_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS invoked_at,
        e.function_name,
        e.ai_provider,
        e.ai_model,
        e.ai_task,
        e.success,
        e.http_status,
        e.duration_ms,
        e.error_type,
        e.error_message
      FROM public.edge_function_invocations e
      WHERE e.invoked_at >= v_start
        AND e.ai_used = true
        AND (v_p1 IS NULL OR e.ai_provider = v_p1)
        AND (v_p2 IS NULL OR e.ai_model = v_p2)
        AND (v_p3 IS NULL OR e.ai_task = v_p3)
      ORDER BY e.invoked_at DESC, e.id DESC
      LIMIT v_fetch
      OFFSET v_offset
    ),
    rows_limited AS (
      SELECT * FROM rows LIMIT v_limit
    ),
    stats AS (
      SELECT (COUNT(*) > v_limit) AS has_more FROM rows
    )
    SELECT jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'param', v_param,
      'rows', COALESCE((SELECT jsonb_agg(to_jsonb(rows_limited)) FROM rows_limited), '[]'::jsonb),
      'has_more', COALESCE((SELECT has_more FROM stats), false)
    ) INTO v_result;
  ELSE
    v_result := jsonb_build_object(
      'metric', v_metric,
      'window', v_window,
      'rows', '[]'::jsonb,
      'has_more', false
    );
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_dashboard_drilldown(text, text, text, integer, integer) TO authenticated;

COMMIT;
