-- Migration: Pinned users count as online in app + admin online counts
-- Date: 2026-10-05
-- Depends on: 20262085000000 (pinned matching/visibility exemptions)
--
-- Companion to 20262085000000: an ACTIVE pin now also feeds the online
-- COUNTERS, both apps. A visible user with an active pin must never show as
-- offline anywhere, and their pin coordinates are real map points, so:
--
--   Main app (regular MatchMe):
--     1. get_online_others_count()            home-screen online counter
--     2. get_online_users_count()             generic online counter
--     3. get_online_users_count_excluding_self() (visibility-filtered)
--     4. get_online_user_counts_by_country()  online world map
--     5. get_online_user_counts_by_country_excluding_self()
--
--   Admin app:
--     6. admin_get_realtime_user_counts()     LIVE online card
--     7. admin_get_user_map_locations()       LIVE map pins (online mode)
--     8. admin_get_dashboard_drilldown()      online_users_live drilldown
--
-- The visible- surfaces (LIVE visible card, visible map mode, visible
-- drilldown, nearby count, map cells) need no change here: they call
-- is_user_truly_visible(), which 20262085000000 already taught to treat an
-- active pin as presence.
--
-- Semantics kept as-is:
--   - Visibility / banned / admin-inclusion policies per surface are
--     unchanged; the pin only bypasses the heartbeat requirement.
--   - Country-map attribution still uses the user's sessions: a pinned user
--     shows on the world map under their session country; with no country on
--     any session they stay off the country map (cannot be placed).
--   - Windowed engagement stats (admin_get_dashboard_stats 24h/7d and the
--     windowed drilldown branches) remain "active during the window"; a user
--     pinned-and-closed for days correctly does not inflate 24h activity.
--
-- Pinned users whose heartbeat stopped keep their stale user_activity row
-- (is_online=false) — every query below was extended with an OR branch on
-- public.is_pinned_location_active(), never a rewrite of the online test.


-- =============================================================
-- (1)
CREATE OR REPLACE FUNCTION public.get_online_others_count(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(*)
  INTO online_count
  FROM public.user_activity ua
  WHERE ua.user_id != p_user_id
    AND (
      (ua.is_online = true AND ua.last_activity > NOW() - INTERVAL '61 seconds')
      OR public.is_pinned_location_active(ua.user_id)
    );

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO anon;

-- (2)
CREATE OR REPLACE FUNCTION public.get_online_users_count(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(DISTINCT ua.user_id)
  INTO online_count
  FROM public.user_activity ua
  WHERE (ua.is_online = true AND ua.last_activity > NOW() - INTERVAL '61 seconds')
    OR public.is_pinned_location_active(ua.user_id);

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO service_role;

COMMENT ON FUNCTION public.get_online_users_count IS
  'Returns the number of distinct users currently online; prevents same-user double counting from stale/duplicate rows.';

-- (3)
CREATE OR REPLACE FUNCTION public.get_online_users_count_excluding_self(p_user_id UUID)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  online_count integer;
BEGIN
  SELECT COUNT(*)
  INTO online_count
  FROM public.user_activity ua
  INNER JOIN public.users u ON ua.user_id = u.id
  WHERE ua.user_id != p_user_id
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    AND (
      (ua.is_online = true AND ua.last_activity > NOW() - INTERVAL '61 seconds')
      OR public.is_pinned_location_active(ua.user_id)
    );

  RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;

-- (4)
CREATE OR REPLACE FUNCTION public.get_online_user_counts_by_country(
  p_recent_seconds integer DEFAULT 61
)
RETURNS TABLE (
  country text,
  user_count integer
)
LANGUAGE plpgsql
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
    SELECT DISTINCT ua.user_id
    FROM public.user_activity ua
    WHERE (ua.is_online = true
      AND ua.last_activity > NOW() - make_interval(secs => v_seconds)
      OR public.is_pinned_location_active(ua.user_id))
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      -- Prefer the newest session WITH a country over a newer one without.
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
  )
  SELECT
    ls.country AS country,
    COUNT(*)::integer AS user_count
  FROM online o
  LEFT JOIN latest_session ls ON ls.user_id = o.user_id
  WHERE ls.country IS NOT NULL
  GROUP BY ls.country
  ORDER BY user_count DESC, ls.country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;

COMMENT ON FUNCTION public.get_online_user_counts_by_country(integer) IS
  'Returns online user counts grouped by country. When a user has several sessions, the newest session WITH a country wins so a country-less session can never hide a valid country.';

-- (5)
CREATE OR REPLACE FUNCTION public.get_online_user_counts_by_country_excluding_self(
  p_user_id uuid,
  p_recent_seconds integer DEFAULT 61
)
RETURNS TABLE (
  country text,
  user_count integer
)
LANGUAGE plpgsql
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
    SELECT DISTINCT ua.user_id
    FROM public.user_activity ua
    WHERE (ua.is_online = true
      AND ua.last_activity > NOW() - make_interval(secs => v_seconds)
      OR public.is_pinned_location_active(ua.user_id))
      AND (p_user_id IS NULL OR ua.user_id != p_user_id)
  ),
  latest_session AS (
    SELECT DISTINCT ON (us.user_id)
      us.user_id,
      NULLIF(btrim(COALESCE(us.country, '')), '') AS country
    FROM public.user_session us
    WHERE us.revoked = false
    ORDER BY
      us.user_id,
      -- Prefer the newest session WITH a country over a newer one without.
      (NULLIF(btrim(COALESCE(us.country, '')), '') IS NOT NULL) DESC,
      us.last_active_at DESC NULLS LAST,
      us.created_at DESC NULLS LAST,
      us.id DESC
  )
  SELECT
    ls.country AS country,
    COUNT(*)::integer AS user_count
  FROM online o
  LEFT JOIN latest_session ls ON ls.user_id = o.user_id
  WHERE ls.country IS NOT NULL
  GROUP BY ls.country
  ORDER BY user_count DESC, ls.country ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country_excluding_self(uuid, integer) TO authenticated;

-- (6)
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
  WHERE (ua.is_online = true AND ua.last_activity > v_now - interval '61 seconds')
    OR public.is_pinned_location_active(ua.user_id);

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

-- (7)
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
    WHERE (ua.is_online = true AND ua.last_activity > v_now - interval '61 seconds')
      OR public.is_pinned_location_active(ua.user_id);

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
    WHERE (ua.is_online = true AND ua.last_activity > v_now - interval '61 seconds')
      OR public.is_pinned_location_active(ua.user_id);

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

-- (8)
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
    -- LIVE: users online right now (61-second heartbeat) or holding an
    -- active pinned location (see 20262086)
    WITH base AS (
      SELECT DISTINCT ua.user_id
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE (ua.is_online = true
        AND ua.last_activity > now() - interval '61 seconds'
        OR public.is_pinned_location_active(ua.user_id))
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
        CASE WHEN jsonb_typeof(up.photos) = 'array' THEN (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1) ELSE NULL END AS photo_url
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
    -- LIVE: only users currently visible right now (online + visibility settings), excluding admins
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
        CASE WHEN jsonb_typeof(up.photos) = 'array' THEN (SELECT p FROM jsonb_array_elements_text(up.photos) AS p WHERE NULLIF(btrim(p), '') IS NOT NULL LIMIT 1) ELSE NULL END AS photo_url
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
    -- Cumulative: show all users who were active during the window, excluding admins
    WITH rows AS (
      SELECT
        ua.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE ua.last_activity >= v_start
        AND COALESCE(u.is_admin, false) = false
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
    -- Cumulative: show users active during the window whose visibility
    -- settings allow them to be visible, excluding admins
    WITH rows AS (
      SELECT
        ua.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE COALESCE(u.user_visibility_setting, false) = true
        AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
        AND COALESCE(u.is_admin, false) = false
        AND ua.last_activity >= v_start
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

