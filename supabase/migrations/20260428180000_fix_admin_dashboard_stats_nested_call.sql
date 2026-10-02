-- Fix admin_get_dashboard_stats to avoid nested function call to admin_get_ai_quota_status
-- The nested call can fail due to auth context issues in SECURITY DEFINER functions
-- causing all analytics to show zeros

BEGIN;

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

  -- New variables for inline quota status query
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

  v_online_users := COALESCE(public.get_online_users_count(auth.uid()), 0);
  SELECT COALESCE(COUNT(*), 0)::int
  INTO v_visible_users
  FROM public.users u
  JOIN public.user_activity ua ON ua.user_id = u.id
  WHERE ua.is_online = true
    AND ua.last_activity > now() - interval '45 seconds'
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible';

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
  WHERE u.created_at >= v_start;

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

  -- Inline the quota status query instead of calling nested function
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
