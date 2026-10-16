-- Migration: Windowed drilldown totals for online/visible users
-- Date: 2026-10-16
-- Purpose: The windowed 'online_users' and 'visible_users' branches of
-- admin_get_dashboard_drilldown omitted total_count, so their drilldown
-- screens could not show the count badge that the LIVE branches show and
-- that the dashboard cards already display (the UI hides the badge when
-- total_count is null). Both branches now return total_count, computed
-- with exactly the same predicates as their rows: each branch's row query
-- was restructured into base/total/rows CTEs so the total can never drift
-- from the listed rows.
--
-- The function body below is copied verbatim from
-- 20262111000000_presence_online_only_and_dashboard_stats.sql with only
-- those two branches modified.

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
    -- Cumulative: show all users who were active during the window, including admins (see 20262095).
    -- total_count (20262120) matches the dashboard card: same predicate as rows.
    WITH base AS (
      SELECT
        ua.user_id AS user_id,
        COALESCE(u.name, 'User ' || substring(ua.user_id::text, 1, 8)) AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.user_activity ua
      JOIN public.users u ON u.id = ua.user_id
      WHERE ua.last_activity >= v_start
        AND COALESCE(u.is_profile_complete, false) = true
    ),
    total AS (
      SELECT COUNT(*)::int AS total_count FROM base
    ),
    rows AS (
      SELECT * FROM base
      ORDER BY last_activity_at DESC, user_id DESC
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
  ELSIF v_metric = 'visible_users' THEN
    -- Cumulative: users who were ACTUALLY visible at some point during the
    -- window (see 20262096) -- same components as is_user_truly_visible()
    -- with the freshness bounds widened to the window, including admins.
    -- Driven from users so pinned-only users (no heartbeat in the window)
    -- are listed too. total_count (20262120) matches the dashboard card:
    -- same predicate as rows.
    WITH base AS (
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
    ),
    total AS (
      SELECT COUNT(*)::int AS total_count FROM base
    ),
    rows AS (
      SELECT * FROM base
      ORDER BY last_activity_at DESC NULLS LAST, user_id DESC
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
