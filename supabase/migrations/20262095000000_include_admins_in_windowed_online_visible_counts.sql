-- Include admin accounts in the WINDOWED online/visible counts (24h / 7d).
--
-- Problem: the admin dashboard's LIVE online/visible cards include admins
-- (fixed by 20262004 / 20262005), but the WINDOWED (24h / 7d) engagement
-- cards and their drilldowns still excluded every user with
-- is_admin = true. An admin who also uses the main MatchMe app daily was
-- therefore counted in the LIVE section but missing from the historic
-- 24h / 7d online and visible counts -- and from those drilldown lists.
--
-- Policy change (windowed section): historic presence counts mean "everyone
-- who was on the network during the window", team members included, so the
-- windowed numbers reconcile with the LIVE cards above them. This mirrors
-- the rationale recorded in 20262004 for the LIVE section.
--
-- Changes (full function bodies replaced, copied verbatim from 20262094):
--  1. admin_get_dashboard_stats(): drop the is_admin = false filter from the
--     windowed online_users and visible_users counts.
--  2. admin_get_dashboard_drilldown(): drop the is_admin = false filter from
--     the windowed 'online_users' and 'visible_users' branches.
--
-- The is_profile_complete = true requirement is kept exactly as in 20262094.

BEGIN;

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
        AND (COALESCE(u.is_profile_complete, false) = true OR COALESCE(u.is_admin, false) = true)
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
    -- Cumulative: show users active during the window whose visibility
    -- settings allow them to be visible, including admins (see 20262095)
    WITH rows AS (
      SELECT
        ua.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE COALESCE(u.user_visibility_setting, false) = true
        AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
        AND COALESCE(u.is_profile_complete, false) = true
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


CREATE OR REPLACE FUNCTION public.admin_get_dashboard_stats(p_window text DEFAULT '24h')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_window text := lower(btrim(COALESCE(p_window, '24h')));
  v_start timestamptz;
  v_step interval;
  v_bucket_trunc text;
  v_series jsonb;

  v_online_users int;
  v_visible_users int;

  v_matches_window int;
  v_messages_window int;
  v_signups_window int;
  v_active_matches_window int;

  v_verification_pending int;
  v_verification_analyzing int;
  v_profile_edits_pending int;
  v_broadcasts_draft int;
  v_broadcasts_scheduled int;
  v_notifications_pending int;
  v_notifications_failed int;

  v_paid_active int;
  v_paid_expiring_7d int;
  v_paid_by_tier jsonb;
  v_earnings_by_currency jsonb;

  v_ai_usage_summary jsonb;
  v_ai_recent_errors jsonb;
  v_edge_functions_summary jsonb;
  v_edge_functions_recent_errors jsonb;

  v_quota_updated_at timestamptz;
  v_quota_providers jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  )
  INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF v_window NOT IN ('24h', '7d') THEN
    v_window := '24h';
  END IF;

  IF v_window = '24h' THEN
    v_bucket_trunc := 'hour';
    v_step := interval '1 hour';
    v_start := date_trunc('hour', now() - interval '23 hours');
  ELSE
    v_bucket_trunc := 'day';
    v_step := interval '1 day';
    v_start := date_trunc('day', now() - interval '6 days');
  END IF;

  -- Cumulative: distinct users active at any point during the window
  -- Includes admin accounts (see 20262095): historic online/visible
  -- counts must match the LIVE cards, which already include admins
  SELECT COALESCE(COUNT(DISTINCT ua.user_id), 0)::int
  INTO v_online_users
  FROM public.user_activity ua
  JOIN public.users u ON u.id = ua.user_id
  WHERE ua.last_activity >= v_start
    AND COALESCE(u.is_profile_complete, false) = true;

  -- Cumulative: distinct users whose visibility settings allow them to be
  -- visible and who were active during the window. Uses direct column checks
  -- instead of is_user_truly_visible() which requires a real-time online
  -- heartbeat and would miss users who were visible earlier in the window
  -- but are currently offline.
  SELECT COALESCE(COUNT(DISTINCT u.id), 0)::int
  INTO v_visible_users
  FROM public.users u
  WHERE COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    AND COALESCE(u.is_profile_complete, false) = true
    AND EXISTS (
      SELECT 1 FROM public.user_activity ua
      WHERE ua.user_id = u.id
        AND ua.last_activity >= v_start
    );

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_matches_window
  FROM public.matches m
  WHERE m.created_at >= v_start;

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_messages_window
  FROM public.chat_messages cm
  WHERE cm.created_at >= v_start;

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_signups_window
  FROM public.users u
  WHERE u.created_at >= v_start
    AND COALESCE(u.is_profile_complete, false) = true;

  SELECT COALESCE(COUNT(DISTINCT c.match_id), 0)::int
  INTO v_active_matches_window
  FROM public.chats c
  WHERE COALESCE(c.last_message_at, c.updated_at) >= v_start;

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_verification_pending
  FROM public.users u
  WHERE u.verification_status = 'pending';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_verification_analyzing
  FROM public.users u
  WHERE u.verification_status = 'analyzing';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_profile_edits_pending
  FROM public.profile_edit_requests r
  WHERE r.status = 'pending';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_broadcasts_draft
  FROM public.admin_broadcasts b
  WHERE b.status = 'draft';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_broadcasts_scheduled
  FROM public.admin_broadcasts b
  WHERE b.status = 'scheduled';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_notifications_pending
  FROM public.notification_queue nq
  WHERE nq.status = 'pending';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_notifications_failed
  FROM public.notification_queue nq
  WHERE nq.status = 'failed';

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_paid_active
  FROM public.users u
  WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
    AND u.subscription_expires_at IS NOT NULL
    AND u.subscription_expires_at > now();

  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_paid_expiring_7d
  FROM public.users u
  WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
    AND u.subscription_expires_at IS NOT NULL
    AND u.subscription_expires_at > now()
    AND u.subscription_expires_at <= now() + interval '7 days';

  SELECT COALESCE(
    (
      SELECT jsonb_object_agg(tier, cnt)
      FROM (
        SELECT
          COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') AS tier,
          COUNT(*)::int AS cnt
        FROM public.users u
        WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
          AND u.subscription_expires_at IS NOT NULL
          AND u.subscription_expires_at > now()
        GROUP BY 1
        ORDER BY 1
      ) s
    ),
    '{}'::jsonb
  )
  INTO v_paid_by_tier;

  SELECT COALESCE(
    (
      SELECT jsonb_object_agg(currency, total_amount) FILTER (WHERE total_amount <> 0)
      FROM (
        SELECT
          COALESCE(
            NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
            NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
            NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currencyCode', ''))), ''),
            'unknown'
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
        WHERE sq.created_at >= (
          CASE
            WHEN v_window = '7d' THEN date_trunc('day', now() - interval '7 days')
            ELSE v_start
          END
        )
          AND COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
          AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
        GROUP BY 1
        ORDER BY 1
      ) s
    ),
    '{}'::jsonb
  )
  INTO v_earnings_by_currency;

  WITH buckets AS (
    SELECT generate_series(
      v_start,
      date_trunc(v_bucket_trunc, now()),
      v_step
    ) AS bucket
  ),
  match_counts AS (
    SELECT date_trunc(v_bucket_trunc, m.created_at) AS bucket, COUNT(*)::int AS c
    FROM public.matches m
    WHERE m.created_at >= v_start
    GROUP BY 1
  ),
  message_counts AS (
    SELECT date_trunc(v_bucket_trunc, cm.created_at) AS bucket, COUNT(*)::int AS c
    FROM public.chat_messages cm
    WHERE cm.created_at >= v_start
    GROUP BY 1
  ),
  signup_counts AS (
    SELECT date_trunc(v_bucket_trunc, u.created_at) AS bucket, COUNT(*)::int AS c
    FROM public.users u
    WHERE u.created_at >= v_start
      AND COALESCE(u.is_profile_complete, false) = true
    GROUP BY 1
  ),
  active_match_counts AS (
    SELECT date_trunc(v_bucket_trunc, COALESCE(c.last_message_at, c.updated_at)) AS bucket, COUNT(DISTINCT c.match_id)::int AS c
    FROM public.chats c
    WHERE COALESCE(c.last_message_at, c.updated_at) >= v_start
    GROUP BY 1
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        't', to_char(b.bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'matches', COALESCE(mc.c, 0),
        'messages', COALESCE(msg.c, 0),
        'signups', COALESCE(sc.c, 0),
        'active_matches', COALESCE(amc.c, 0)
      )
      ORDER BY b.bucket
    ),
    '[]'::jsonb
  )
  INTO v_series
  FROM buckets b
  LEFT JOIN match_counts mc ON mc.bucket = b.bucket
  LEFT JOIN message_counts msg ON msg.bucket = b.bucket
  LEFT JOIN signup_counts sc ON sc.bucket = b.bucket
  LEFT JOIN active_match_counts amc ON amc.bucket = b.bucket;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'provider', provider,
        'model', model,
        'task', task,
        'calls', calls,
        'failures', failures
      )
      ORDER BY calls DESC
    ),
    '[]'::jsonb
  )
  INTO v_ai_usage_summary
  FROM (
    SELECT
      COALESCE(NULLIF(btrim(COALESCE(efi.ai_provider, '')), ''), 'unknown') AS provider,
      COALESCE(NULLIF(btrim(COALESCE(efi.ai_model, '')), ''), 'unknown') AS model,
      COALESCE(NULLIF(btrim(COALESCE(efi.ai_task, '')), ''), 'unknown') AS task,
      COUNT(*)::int AS calls,
      COUNT(*) FILTER (WHERE efi.success = false)::int AS failures
    FROM public.edge_function_invocations efi
    WHERE efi.invoked_at >= v_start
      AND efi.ai_used = true
    GROUP BY 1, 2, 3
    ORDER BY COUNT(*) DESC
    LIMIT 20
  ) s;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        't', to_char(invoked_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'function', function_name,
        'provider', COALESCE(NULLIF(btrim(COALESCE(ai_provider, '')), ''), 'unknown'),
        'model', COALESCE(NULLIF(btrim(COALESCE(ai_model, '')), ''), 'unknown'),
        'task', COALESCE(NULLIF(btrim(COALESCE(ai_task, '')), ''), 'unknown'),
        'request_id', request_id::text,
        'error_type', error_type,
        'error_message', error_message,
        'http_status', http_status
      )
      ORDER BY invoked_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_ai_recent_errors
  FROM (
    SELECT invoked_at, function_name, ai_provider, ai_model, ai_task, request_id, error_type, error_message, http_status
    FROM public.edge_function_invocations
    WHERE invoked_at >= v_start
      AND ai_used = true
      AND success = false
    ORDER BY invoked_at DESC
    LIMIT 25
  ) e;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'function', function_name,
        'calls', calls,
        'failures', failures,
        'last_error_at', CASE
          WHEN last_error_at IS NULL THEN NULL
          ELSE to_char(last_error_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        END
      )
      ORDER BY calls DESC
    ),
    '[]'::jsonb
  )
  INTO v_edge_functions_summary
  FROM (
    SELECT
      efi.function_name,
      COUNT(*)::int AS calls,
      COUNT(*) FILTER (WHERE efi.success = false)::int AS failures,
      MAX(efi.invoked_at) FILTER (WHERE efi.success = false) AS last_error_at
    FROM public.edge_function_invocations efi
    WHERE efi.invoked_at >= v_start
    GROUP BY 1
    ORDER BY COUNT(*) DESC
    LIMIT 20
  ) s;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        't', to_char(invoked_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'function', function_name,
        'request_id', request_id::text,
        'error_type', error_type,
        'error_message', error_message,
        'http_status', http_status
      )
      ORDER BY invoked_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_edge_functions_recent_errors
  FROM (
    SELECT invoked_at, function_name, request_id, error_type, error_message, http_status
    FROM public.edge_function_invocations
    WHERE invoked_at >= v_start
      AND success = false
    ORDER BY invoked_at DESC
    LIMIT 25
  ) e;

  SELECT MAX(updated_at) INTO v_quota_updated_at
  FROM public.ai_quota_status;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'provider', provider,
        'updated_at', CASE
          WHEN provider_updated_at IS NULL THEN NULL
          ELSE to_char(provider_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        END,
        'metrics', metrics
      )
      ORDER BY provider
    ),
    '[]'::jsonb
  )
  INTO v_quota_providers
  FROM (
    SELECT
      provider,
      MAX(updated_at) AS provider_updated_at,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'metric', metric,
            'window', window_key,
            'used', used,
            'limit', limit_value,
            'unit', unit,
            'status', status,
            'start_time', CASE
              WHEN start_time IS NULL THEN NULL
              ELSE to_char(start_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            END,
            'end_time', CASE
              WHEN end_time IS NULL THEN NULL
              ELSE to_char(end_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            END,
            'updated_at', to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'details', details
          )
          ORDER BY metric, window_key
        ),
        '[]'::jsonb
      ) AS metrics
    FROM public.ai_quota_status
    GROUP BY provider
  ) s;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'window', v_window,
    'engagement', jsonb_build_object(
      'online_users', v_online_users,
      'visible_users', v_visible_users,
      'matches_created', v_matches_window,
      'messages_sent', v_messages_window,
      'new_users', v_signups_window,
      'active_matches', v_active_matches_window
    ),
    'engagement_series', v_series,
    'operations', jsonb_build_object(
      'verification_pending', v_verification_pending,
      'verification_analyzing', v_verification_analyzing,
      'profile_edits_pending', v_profile_edits_pending,
      'broadcasts_draft', v_broadcasts_draft,
      'broadcasts_scheduled', v_broadcasts_scheduled,
      'notifications_pending', v_notifications_pending,
      'notifications_failed', v_notifications_failed
    ),
    'revenue', jsonb_build_object(
      'paid_active_users', v_paid_active,
      'paid_expiring_7d', v_paid_expiring_7d,
      'paid_by_tier', v_paid_by_tier,
      'earnings_by_currency', v_earnings_by_currency
    ),
    'safety', jsonb_build_object(
      'available', false
    ),
    'ai', jsonb_build_object(
      'usage', v_ai_usage_summary,
      'recent_errors', v_ai_recent_errors,
      'quota_status', jsonb_build_object(
        'updated_at', CASE
          WHEN v_quota_updated_at IS NULL THEN NULL
          ELSE to_char(v_quota_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        END,
        'providers', v_quota_providers
      )
    ),
    'edge_functions', jsonb_build_object(
      'usage', v_edge_functions_summary,
      'recent_errors', v_edge_functions_recent_errors
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_dashboard_stats(text) TO authenticated;

COMMIT;
