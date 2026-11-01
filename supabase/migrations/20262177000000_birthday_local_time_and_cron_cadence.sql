-- Birthday automation correctness + durable cron cadence.
--
-- Problems fixed:
--   * The birthday sweep used UTC CURRENT_DATE for every recipient, so users
--     east/west of UTC were wished on the wrong local day (and near New Year
--     the delivery key used the wrong year).
--   * It ran on every one-minute tick, rescanning the full broadcast audience
--     even though a birthday can only become due once per day.
--   * A birthday push could be dropped by the general admin-broadcast
--     frequency cap: the delivery row was written as 'skipped' and the yearly
--     unique key then prevented any retry. Birthday pushes are at most one per
--     user per year and are already deduped, so they are exempt from that cap.
--
-- Also adds cron_task_state/claim_cron_task so expensive edge tasks can claim
-- a durable minimum interval instead of relying on in-process memory (every
-- edge invocation is a fresh isolate).

BEGIN;

-- users.user_timezone is written by upsert_user_session()/profile saves and
-- read by the client; make the dependency explicit for schema-only databases.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS user_timezone TEXT;

-- ---------------------------------------------------------------------------
-- 1) Durable cadence claims for cron tasks.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cron_task_state (
  task_name TEXT PRIMARY KEY,
  last_started_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.cron_task_state ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.cron_task_state FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.cron_task_state TO service_role;

CREATE OR REPLACE FUNCTION public.claim_cron_task(
  p_task_name TEXT,
  p_min_seconds INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name TEXT;
  v_claimed BOOLEAN;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_name := NULLIF(btrim(COALESCE(p_task_name, '')), '');
  IF v_name IS NULL OR char_length(v_name) > 100 THEN
    RAISE EXCEPTION 'invalid cron task name';
  END IF;
  IF p_min_seconds IS NULL OR p_min_seconds < 0 THEN
    RAISE EXCEPTION 'invalid cron task interval';
  END IF;

  INSERT INTO public.cron_task_state AS state (task_name, last_started_at)
  VALUES (v_name, now())
  ON CONFLICT (task_name) DO UPDATE
    SET last_started_at = now()
    WHERE state.last_started_at <= now() - make_interval(secs => p_min_seconds)
  RETURNING TRUE INTO v_claimed;

  -- No row returned means the previous claim is still inside its interval.
  RETURN COALESCE(v_claimed, false);
END;
$$;

REVOKE ALL ON FUNCTION public.claim_cron_task(TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_cron_task(TEXT, INTEGER) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Birthday sweep: per-recipient local date and local year.
--
-- Each user is evaluated in users.user_timezone (validated against
-- pg_timezone_names, falling back to UTC). The push is released from 09:00
-- local time so the first hourly tick after morning sends it; later hourly
-- ticks catch users whose token appears during the day.
--
-- Feb 29 birthdays are observed on Feb 28 in non-leap years instead of being
-- silently skipped for three years out of four.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_birthday_broadcast_notifications(
  p_broadcast_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b RECORD;
  target_user RECORD;
  v_first TEXT;
  v_title TEXT;
  v_msg TEXT;
  v_action_text TEXT;
  v_action_url TEXT;
  v_count INTEGER := 0;
  v_issues TEXT[];
  v_delivery_id UUID;
  v_delivery_key TEXT;
BEGIN
  SELECT * INTO b FROM public.admin_broadcasts WHERE id = p_broadcast_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;
  IF COALESCE(b.automation_enabled, false) = false THEN
    RETURN 0;
  END IF;
  IF COALESCE(b.automation_type, '') <> 'birthday' THEN
    RETURN 0;
  END IF;

  v_issues := public.check_notification_limits(
    b.title, b.message, b.action_url, b.action_url_text
  );
  -- Validate template with placeholder removed (personalized text is shorter).
  IF array_length(v_issues, 1) > 0
     AND NOT (array_length(v_issues, 1) = 1 AND v_issues[1] LIKE 'Message max%') THEN
    RAISE EXCEPTION 'Broadcast violates limits: %', array_to_string(v_issues, '; ');
  END IF;

  FOR target_user IN
    WITH valid_tz AS MATERIALIZED (
      SELECT name FROM pg_timezone_names
    )
    SELECT c.user_id, c.fcm_token, c.platform, c.name, c.local_now
    FROM (
      SELECT
        gufb.user_id,
        gufb.fcm_token,
        gufb.platform,
        u.name,
        u.date_of_birth,
        COALESCE(
          NOW() AT TIME ZONE tz.name,
          NOW() AT TIME ZONE 'UTC'
        ) AS local_now
      FROM public.get_users_for_broadcast(COALESCE(b.filter_criteria, '{}')) AS gufb
      JOIN public.users u ON u.id = gufb.user_id
      LEFT JOIN valid_tz AS tz
        ON tz.name = NULLIF(btrim(u.user_timezone), '')
      WHERE u.date_of_birth IS NOT NULL
    ) c
    WHERE (
      (
        EXTRACT(MONTH FROM c.date_of_birth) = EXTRACT(MONTH FROM c.local_now)
        AND EXTRACT(DAY FROM c.date_of_birth) = EXTRACT(DAY FROM c.local_now)
      )
      OR (
        EXTRACT(MONTH FROM c.date_of_birth) = 2
        AND EXTRACT(DAY FROM c.date_of_birth) = 29
        AND EXTRACT(MONTH FROM c.local_now) = 2
        AND EXTRACT(DAY FROM c.local_now) = 28
        AND NOT (
          EXTRACT(YEAR FROM c.local_now)::int % 4 = 0
          AND (
            EXTRACT(YEAR FROM c.local_now)::int % 100 <> 0
            OR EXTRACT(YEAR FROM c.local_now)::int % 400 = 0
          )
        )
      )
    )
    AND EXTRACT(HOUR FROM c.local_now) >= 9
    -- Users already handled for this local year must not consume the LIMIT:
    -- with more than 20k same-day birthdays the first page would otherwise be
    -- re-selected every tick and later users would never be wished.
    AND NOT EXISTS (
      SELECT 1 FROM public.admin_broadcast_deliveries d
      WHERE d.broadcast_id = p_broadcast_id
        AND d.user_id = c.user_id
        AND d.delivery_key = 'birthday:' || to_char(c.local_now, 'YYYY')
    )
    ORDER BY c.user_id
    LIMIT 20000
  LOOP
    v_delivery_key := 'birthday:' || to_char(target_user.local_now, 'YYYY');
    v_delivery_id := NULL;

    INSERT INTO public.admin_broadcast_deliveries (
      broadcast_id, user_id, fcm_token, platform, delivery_status, delivery_key
    )
    VALUES (
      p_broadcast_id, target_user.user_id, target_user.fcm_token,
      target_user.platform, 'pending', v_delivery_key
    )
    ON CONFLICT (broadcast_id, user_id, delivery_key) DO NOTHING
    RETURNING id INTO v_delivery_id;

    IF v_delivery_id IS NULL THEN
      CONTINUE;  -- already sent this local year
    END IF;

    v_first := split_part(btrim(COALESCE(target_user.name, '')), ' ', 1);
    IF v_first = '' THEN v_first := 'there'; END IF;
    IF char_length(v_first) > 20 THEN v_first := substr(v_first, 1, 20); END IF;

    v_title := REPLACE(REPLACE(COALESCE(b.title, ''), '{first_name}', v_first), '{name}', v_first);
    v_msg := REPLACE(REPLACE(COALESCE(b.message, ''), '{first_name}', v_first), '{name}', v_first);
    v_action_text := REPLACE(REPLACE(COALESCE(b.action_url_text, ''), '{first_name}', v_first), '{name}', v_first);
    v_action_url := REPLACE(REPLACE(COALESCE(b.action_url, ''), '{first_name}', v_first), '{name}', v_first);

    v_title := public.truncate_notif_text(btrim(v_title), 200);
    v_msg := public.truncate_notif_text(btrim(v_msg), 1000);

    BEGIN
      PERFORM public.queue_fcm_notification(
        target_user.user_id,
        target_user.fcm_token,
        v_title,
        v_msg,
        jsonb_build_object(
          'type', 'admin_broadcast',
          'broadcast_id', p_broadcast_id,
          'action_url', NULLIF(v_action_url, ''),
          'action_url_text', NULLIF(v_action_text, '')
        ),
        target_user.platform
      );

      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'sent', sent_at = NOW(), failure_reason = NULL
      WHERE id = v_delivery_id;

      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'failed', failure_reason = left(SQLERRM, 500)
      WHERE id = v_delivery_id;
    END;
  END LOOP;

  UPDATE public.admin_broadcasts
  SET actual_sent_count = COALESCE(actual_sent_count, 0) + v_count,
      updated_at = NOW()
  WHERE id = p_broadcast_id;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_birthday_broadcast_notifications(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_birthday_broadcast_notifications(UUID)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Fix batch starvation in claim_profile_reminder_candidates.
--
-- The LIMIT was applied before the "claimable" filters, so users already at
-- their max stage (or already recorded for this activity) kept occupying the
-- entire batch: the queue RPC saw no new rows and no one else was ever
-- reminded. The filter now runs inside the limited query, and rows that the
-- ON CONFLICT guard would discard are excluded before the LIMIT.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_profile_reminder_candidates(
  p_offsets_hours double precision[] DEFAULT ARRAY[1, 5]::double precision[],
  p_repeat_hours double precision DEFAULT 24,
  p_max_reminders integer DEFAULT 0,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (user_id uuid, fcm_token text, platform text, ui_language text, display_name text, stage integer, hours_closed double precision)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_sorted double precision[];
  v_n integer;
  v_first double precision;
  v_last double precision;
  v_limit integer;
BEGIN
  SELECT COALESCE(array_agg(DISTINCT o ORDER BY o), ARRAY[]::double precision[])
  INTO v_sorted
  FROM unnest(COALESCE(p_offsets_hours, ARRAY[1, 5]::double precision[])) AS o
  WHERE o IS NOT NULL AND o > 0;
  IF v_sorted IS NULL OR array_length(v_sorted, 1) = 0 THEN
    v_sorted := ARRAY[1.0, 5.0]::double precision[];
  END IF;
  v_n := array_length(v_sorted, 1);
  v_first := v_sorted[1];
  v_last := v_sorted[v_n];
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 2000), 1);

  RETURN QUERY
  WITH cand AS (
    SELECT DISTINCT ON (u.id)
      u.id AS user_id,
      ua.last_activity AS closed_at,
      us.metadata->>'fcm_token' AS fcm_token,
      us.platform AS platform,
      COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language, ''))), ''), 'en') AS ui_language,
      COALESCE(u.name, '') AS display_name
    FROM public.users u
    JOIN public.user_activity ua ON ua.user_id = u.id
    JOIN public.user_session us ON us.user_id = u.id
    WHERE us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE(u.is_profile_complete, false) = false
      AND COALESCE(u.is_admin, false) = false
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
            (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
            (u.notification_preferences->>'enable_admin_notifications')::boolean, true) = true
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ),
  due AS (
    SELECT
      c.*,
      (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0)::double precision AS hours_closed,
      GREATEST(
        (SELECT COUNT(*)::int FROM unnest(v_sorted) AS o
          WHERE (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= o),
        CASE
          WHEN p_repeat_hours > 0
            AND (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= v_last + p_repeat_hours
          THEN v_n + FLOOR(((EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) - v_last) / p_repeat_hours)::int
          ELSE 0
        END
      ) AS due_stage
    FROM cand c
    WHERE (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= v_first
  ),
  batch AS (
    SELECT d.*
    FROM due d
    LEFT JOIN public.profile_reminder_state prs ON prs.user_id = d.user_id
    WHERE d.due_stage >= 1
      AND (COALESCE(p_max_reminders, 0) <= 0 OR d.due_stage <= p_max_reminders)
      AND (
        prs.user_id IS NULL
        OR prs.stage < d.due_stage
        OR prs.last_activity_at < d.closed_at
      )
    ORDER BY d.closed_at DESC
    LIMIT v_limit
  ),
  claimed AS (
    INSERT INTO public.profile_reminder_state
      (user_id, stage, last_activity_at, last_sent_at, updated_at)
    SELECT b.user_id, b.due_stage, b.closed_at, now(), now()
    FROM batch b
    ON CONFLICT (user_id) DO UPDATE
      SET stage = EXCLUDED.stage,
          last_activity_at = EXCLUDED.last_activity_at,
          last_sent_at = now(),
          updated_at = now()
      WHERE profile_reminder_state.stage < EXCLUDED.stage
         OR profile_reminder_state.last_activity_at < EXCLUDED.last_activity_at
    RETURNING user_id AS claimed_user_id, stage AS claimed_stage
  )
  SELECT cl.claimed_user_id, b.fcm_token, b.platform, b.ui_language, b.display_name,
         cl.claimed_stage, b.hours_closed
  FROM claimed cl
  JOIN batch b ON b.user_id = cl.claimed_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_profile_reminder_candidates(double precision[], double precision, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_profile_reminder_candidates(double precision[], double precision, integer, integer)
  TO service_role;

-- Profile reminders have their own offsets/repeat/max controls; the general
-- admin-announcement cap must not consume a reminder stage and silently lose
-- it (the claim is recorded before the queue write).
CREATE OR REPLACE FUNCTION public.queue_profile_reminder_broadcast_notifications(
  p_broadcast_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b RECORD;
  target_user RECORD;
  v_first TEXT;
  v_title TEXT;
  v_msg TEXT;
  v_action_text TEXT;
  v_action_url TEXT;
  v_count INTEGER := 0;
  v_issues TEXT[];
  v_enabled_cfg boolean;
  v_cfg JSONB;
  v_offsets double precision[] := ARRAY[1.0, 5.0]::double precision[];
  v_repeat INT;
  v_max INT;
  v_batch INT;
  v_delivery_id UUID;
  v_day_key TEXT := 'reminder:' || to_char(NOW(), 'YYYY-MM-DD');
BEGIN
  SELECT * INTO b FROM public.admin_broadcasts WHERE id = p_broadcast_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;
  IF COALESCE(b.automation_enabled, false) = false THEN
    RETURN 0;
  END IF;
  IF COALESCE(b.automation_type, '') <> 'profile_reminder' THEN
    RETURN 0;
  END IF;

  -- Global kill switch (app_config) on top of the per-broadcast toggle.
  BEGIN
    SELECT COALESCE((config_value #>> '{}')::boolean, true) INTO v_enabled_cfg
    FROM public.app_config
    WHERE config_key = 'notifications.profile_reminder.enabled';
  EXCEPTION WHEN OTHERS THEN
    v_enabled_cfg := true;
  END;
  IF COALESCE(v_enabled_cfg, true) = false THEN
    RETURN 0;
  END IF;

  -- Intervals (hours after the app was closed) from app_config.
  BEGIN
    SELECT config_value INTO v_cfg FROM public.app_config
    WHERE config_key = 'notifications.profile_reminder.offsets_hours';
    IF v_cfg IS NOT NULL AND jsonb_typeof(v_cfg) = 'array' THEN
      WITH vals AS (
        SELECT (e::text)::double precision AS v
        FROM jsonb_array_elements_text(v_cfg) AS e
      )
      SELECT COALESCE(array_agg(DISTINCT v ORDER BY v), ARRAY[1.0, 5.0]::double precision[])
      INTO v_offsets
      FROM vals
      WHERE v IS NOT NULL AND v > 0;
      IF array_length(v_offsets, 1) = 0 THEN
        v_offsets := ARRAY[1.0, 5.0]::double precision[];
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_offsets := ARRAY[1.0, 5.0]::double precision[];
  END;

  BEGIN v_repeat := GREATEST(public.app_config_int('notifications.profile_reminder.repeat_hours', 24), 0);
  EXCEPTION WHEN OTHERS THEN v_repeat := 24; END;
  BEGIN v_max := GREATEST(public.app_config_int('notifications.profile_reminder.max_reminders', 0), 0);
  EXCEPTION WHEN OTHERS THEN v_max := 0; END;
  BEGIN v_batch := GREATEST(LEAST(public.app_config_int('notifications.profile_reminder.batch_limit', 200), 2000), 1);
  EXCEPTION WHEN OTHERS THEN v_batch := 200; END;

  v_issues := public.check_notification_limits(
    b.title, b.message, b.action_url, b.action_url_text
  );
  -- Validate template with placeholder removed (personalized text is shorter).
  IF array_length(v_issues, 1) > 0
     AND NOT (array_length(v_issues, 1) = 1 AND v_issues[1] LIKE 'Message max%') THEN
    RAISE EXCEPTION 'Broadcast violates limits: %', array_to_string(v_issues, '; ');
  END IF;

  FOR target_user IN
    SELECT * FROM public.claim_profile_reminder_candidates(
      v_offsets, v_repeat, v_max, v_batch
    )
  LOOP
    v_delivery_id := NULL;
    INSERT INTO public.admin_broadcast_deliveries (
      broadcast_id, user_id, fcm_token, platform, delivery_status, delivery_key
    )
    VALUES (
      p_broadcast_id, target_user.user_id, target_user.fcm_token,
      target_user.platform, 'pending', v_day_key
    )
    ON CONFLICT (broadcast_id, user_id, delivery_key) DO NOTHING
    RETURNING id INTO v_delivery_id;

    IF v_delivery_id IS NULL THEN
      CONTINUE;  -- already sent a reminder for this broadcast today
    END IF;

    v_first := split_part(btrim(COALESCE(target_user.display_name, '')), ' ', 1);
    IF v_first = '' THEN v_first := 'there'; END IF;
    IF char_length(v_first) > 20 THEN v_first := substr(v_first, 1, 20); END IF;

    v_title := REPLACE(REPLACE(COALESCE(b.title, ''), '{first_name}', v_first), '{name}', v_first);
    v_msg := REPLACE(REPLACE(COALESCE(b.message, ''), '{first_name}', v_first), '{name}', v_first);
    v_action_text := REPLACE(REPLACE(COALESCE(b.action_url_text, ''), '{first_name}', v_first), '{name}', v_first);
    v_action_url := REPLACE(REPLACE(COALESCE(b.action_url, ''), '{first_name}', v_first), '{name}', v_first);

    v_title := public.truncate_notif_text(btrim(v_title), 200);
    v_msg := public.truncate_notif_text(btrim(v_msg), 1000);

    BEGIN
      PERFORM public.queue_fcm_notification(
        target_user.user_id,
        target_user.fcm_token,
        v_title,
        v_msg,
        jsonb_build_object(
          'type', 'admin_broadcast',
          'broadcast_id', p_broadcast_id,
          'action_url', NULLIF(v_action_url, ''),
          'action_url_text', NULLIF(v_action_text, '')
        ),
        target_user.platform
      );

      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'sent', sent_at = NOW(), failure_reason = NULL
      WHERE id = v_delivery_id;

      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'failed', failure_reason = left(SQLERRM, 500)
      WHERE id = v_delivery_id;
    END;
  END LOOP;

  UPDATE public.admin_broadcasts
  SET actual_sent_count = COALESCE(actual_sent_count, 0) + v_count,
      updated_at = NOW()
  WHERE id = p_broadcast_id;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_profile_reminder_broadcast_notifications(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_profile_reminder_broadcast_notifications(UUID)
  TO service_role;

COMMIT;
