-- Add per-user earnings to paid-users drilldowns (admin_get_dashboard_drilldown)

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

  v_window := COALESCE(NULLIF(trim(p_window), ''), '24h');
  IF v_window NOT IN ('24h', '7d') THEN
    v_window := '24h';
  END IF;

  v_metric := COALESCE(NULLIF(trim(p_metric), ''), '');
  v_param := NULLIF(trim(COALESCE(p_param, '')), '');
  v_p1 := NULLIF(trim(split_part(COALESCE(v_param, ''), '|', 1)), '');
  v_p2 := NULLIF(trim(split_part(COALESCE(v_param, ''), '|', 2)), '');
  v_p3 := NULLIF(trim(split_part(COALESCE(v_param, ''), '|', 3)), '');

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 500), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_fetch := v_limit + 1;

  IF v_window = '24h' THEN
    v_start := date_trunc('hour', now() - interval '23 hours');
  ELSE
    v_start := date_trunc('day', now() - interval '6 days');
  END IF;

  IF v_metric = 'online_users' THEN
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.users u
      JOIN public.user_activity ua ON ua.user_id = u.id
      WHERE ua.is_online = true
        AND ua.last_activity > now() - interval '45 seconds'
      ORDER BY ua.last_activity DESC, u.id DESC
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
    WITH rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        ua.last_activity AS last_activity_at
      FROM public.users u
      JOIN public.user_activity ua ON ua.user_id = u.id
      WHERE ua.is_online = true
        AND ua.last_activity > now() - interval '45 seconds'
        AND COALESCE(u.user_visibility_setting, false) = true
        AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
      ORDER BY ua.last_activity DESC, u.id DESC
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
          ARRAY(
            SELECT x
            FROM unnest(
              ARRAY[
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
          ARRAY(
            SELECT x
            FROM unnest(
              ARRAY[
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
        u.verification_status,
        u.verification_submitted_at
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
        u.verification_status,
        u.verification_submitted_at
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
        r.id AS request_id,
        r.user_id,
        u.name AS user_name,
        r.created_at,
        r.message
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
        b.id AS broadcast_id,
        b.title,
        b.status,
        b.scheduled_at,
        b.created_at,
        b.target_user_count
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
        b.id AS broadcast_id,
        b.title,
        b.status,
        b.scheduled_at,
        b.created_at,
        b.target_user_count
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
        n.id AS notification_id,
        n.user_id,
        u.name AS user_name,
        n.title,
        n.status,
        n.attempts,
        n.scheduled_at,
        n.created_at
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
        n.id AS notification_id,
        n.user_id,
        u.name AS user_name,
        n.title,
        n.status,
        n.attempts,
        n.failure_reason,
        n.scheduled_at,
        n.created_at
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
    WITH earnings_currency AS (
      SELECT
        sq.user_id,
        COALESCE(
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currencyCode', ''))), ''),
          'UNK'
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
      WHERE COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
        AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
      GROUP BY 1, 2
    ),
    earnings_json AS (
      SELECT
        user_id,
        COALESCE(
          jsonb_object_agg(currency, total_amount) FILTER (WHERE total_amount <> 0),
          '{}'::jsonb
        ) AS earnings
      FROM earnings_currency
      GROUP BY user_id
    ),
    rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        u.subscription_tier,
        u.subscription_expires_at,
        COALESCE(ej.earnings, '{}'::jsonb) AS earnings
      FROM public.users u
      LEFT JOIN earnings_json ej ON ej.user_id = u.id
      WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
        AND u.subscription_expires_at IS NOT NULL
        AND u.subscription_expires_at > now()
      ORDER BY u.subscription_expires_at ASC, u.id DESC
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
    WITH earnings_currency AS (
      SELECT
        sq.user_id,
        COALESCE(
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currencyCode', ''))), ''),
          'UNK'
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
      WHERE COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
        AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
      GROUP BY 1, 2
    ),
    earnings_json AS (
      SELECT
        user_id,
        COALESCE(
          jsonb_object_agg(currency, total_amount) FILTER (WHERE total_amount <> 0),
          '{}'::jsonb
        ) AS earnings
      FROM earnings_currency
      GROUP BY user_id
    ),
    rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        u.subscription_tier,
        u.subscription_expires_at,
        COALESCE(ej.earnings, '{}'::jsonb) AS earnings
      FROM public.users u
      LEFT JOIN earnings_json ej ON ej.user_id = u.id
      WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
        AND u.subscription_expires_at IS NOT NULL
        AND u.subscription_expires_at > now()
        AND u.subscription_expires_at <= now() + interval '7 days'
      ORDER BY u.subscription_expires_at ASC, u.id DESC
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
    WITH earnings_currency AS (
      SELECT
        sq.user_id,
        COALESCE(
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency', ''))), ''),
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currency_code', ''))), ''),
          NULLIF(upper(btrim(COALESCE(sq.purchase_metadata ->> 'currencyCode', ''))), ''),
          'UNK'
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
      WHERE COALESCE(NULLIF(btrim(COALESCE(sq.payment_provider, '')), ''), '') <> ''
        AND COALESCE(lower(btrim(COALESCE(sq.status, ''))), '') <> 'cancelled'
      GROUP BY 1, 2
    ),
    earnings_json AS (
      SELECT
        user_id,
        COALESCE(
          jsonb_object_agg(currency, total_amount) FILTER (WHERE total_amount <> 0),
          '{}'::jsonb
        ) AS earnings
      FROM earnings_currency
      GROUP BY user_id
    ),
    rows AS (
      SELECT
        u.id AS user_id,
        u.name AS user_name,
        COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') AS subscription_tier,
        u.subscription_expires_at,
        COALESCE(ej.earnings, '{}'::jsonb) AS earnings
      FROM public.users u
      LEFT JOIN earnings_json ej ON ej.user_id = u.id
      WHERE COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') <> 'free'
        AND u.subscription_expires_at IS NOT NULL
        AND u.subscription_expires_at > now()
        AND (v_param IS NULL OR COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') = v_param)
      ORDER BY u.subscription_expires_at ASC, u.id DESC
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
        e.request_id,
        e.function_name,
        e.invoked_at,
        e.duration_ms,
        e.success,
        e.http_status,
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
        e.request_id,
        e.function_name,
        e.invoked_at,
        e.duration_ms,
        e.success,
        e.http_status,
        e.error_type,
        e.error_message,
        e.ai_provider,
        e.ai_model,
        e.ai_task
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
