-- Make scheduled admin broadcasts resumable and idempotent.
--
-- Problems in the previous pipeline:
--   * Offsets were recomputed from get_users_for_broadcast() on every chunk,
--     so a retry (edge timeout, overlapping tick) queued duplicate pushes and
--     duplicate delivery rows.
--   * A crash/timeout mid-fan-out left status='sending' forever: the edge only
--     selected 'scheduled', so the rest of the audience never got the push.
--   * The "final chunk" test (scanned < limit) only works with an extra probe
--     and audience totals above the 11-chunk loop were stranded.
--   * A 7-day notification_queue prune ran on every chunk.
--
-- The broadcast now snapshots its audience once into admin_broadcast_deliveries
-- (one row per recipient, unique per broadcast + delivery_key), streams pending
-- rows with FOR UPDATE SKIP LOCKED, and marks each row sent/skipped/failed in
-- the same transaction that queues the push. A retry resumes exactly where the
-- last committed chunk stopped, and concurrent ticks cannot double-send.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Delivery rows: support recipient dedupe across regular broadcasts,
--    yearly birthdays and daily profile reminders.
-- ---------------------------------------------------------------------------
ALTER TABLE public.admin_broadcast_deliveries
  ADD COLUMN IF NOT EXISTS platform TEXT,
  ADD COLUMN IF NOT EXISTS delivery_key TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ;

ALTER TABLE public.admin_broadcast_deliveries
  DROP CONSTRAINT IF EXISTS admin_broadcast_deliveries_delivery_status_check;

ALTER TABLE public.admin_broadcast_deliveries
  ADD CONSTRAINT admin_broadcast_deliveries_delivery_status_check
  CHECK (delivery_status IN ('pending', 'sent', 'skipped', 'delivered', 'failed'));

-- Backfill keys for rows written before this migration.
UPDATE public.admin_broadcast_deliveries d
SET delivery_key = CASE
  WHEN b.automation_type = 'birthday' THEN 'birthday:' || to_char(d.created_at, 'YYYY')
  WHEN b.automation_type = 'profile_reminder' THEN 'reminder:' || to_char(d.created_at, 'YYYY-MM-DD')
  ELSE 'once'
END
FROM public.admin_broadcasts b
WHERE b.id = d.broadcast_id
  AND d.delivery_key = '';

-- Old retries could have inserted the same recipient twice; keep the earliest.
DELETE FROM public.admin_broadcast_deliveries d
USING public.admin_broadcast_deliveries x
WHERE d.broadcast_id = x.broadcast_id
  AND d.user_id = x.user_id
  AND d.delivery_key = x.delivery_key
  AND d.id > x.id;

CREATE UNIQUE INDEX IF NOT EXISTS ux_admin_broadcast_deliveries_recipient
  ON public.admin_broadcast_deliveries (broadcast_id, user_id, delivery_key);

CREATE INDEX IF NOT EXISTS idx_admin_broadcast_deliveries_pending
  ON public.admin_broadcast_deliveries (broadcast_id, id)
  WHERE delivery_status = 'pending';

-- ---------------------------------------------------------------------------
-- 2) send_admin_broadcast: snapshot once, then stream pending rows.
--    p_offset is retained for API compatibility and ignored.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_admin_broadcast(
  broadcast_id UUID,
  p_limit INT DEFAULT 20000,
  p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  broadcast_record public.admin_broadcasts%ROWTYPE;
  target_delivery RECORD;
  c JSONB;
  v_issues TEXT[];
  v_limit INT;
  v_freq_limit INT;
  v_sent INT := 0;
  v_failed INT := 0;
  v_skipped INT := 0;
  v_pending INT := 0;
  v_total INT := 0;
  v_processed INT := 0;
BEGIN
  -- Serialise concurrent invocations for the same broadcast.
  SELECT * INTO broadcast_record
  FROM public.admin_broadcasts
  WHERE id = broadcast_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;

  v_issues := public.check_notification_limits(
    broadcast_record.title, broadcast_record.message,
    broadcast_record.action_url, broadcast_record.action_url_text
  );
  IF array_length(v_issues, 1) > 0 THEN
    UPDATE public.admin_broadcasts
    SET status = 'failed', updated_at = NOW()
    WHERE id = broadcast_id;
    RETURN jsonb_build_object('success', false, 'errors', to_jsonb(v_issues));
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 20000), 20000), 1);
  v_freq_limit := GREATEST(
    public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1
  );
  c := public.normalize_broadcast_filter_criteria(broadcast_record.filter_criteria);

  IF broadcast_record.status IN ('draft', 'scheduled', 'failed') THEN
    UPDATE public.admin_broadcasts
    SET status = 'sending',
        sent_at = NOW(),
        filter_criteria = c,
        skipped_count = 0,
        updated_at = NOW()
    WHERE id = broadcast_id;
  END IF;

  -- Snapshot the audience exactly once. DISTINCT ON collapses users with
  -- several live sessions to one push; ON CONFLICT makes a re-entry no-op.
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_broadcast_deliveries
    WHERE broadcast_id = send_admin_broadcast.broadcast_id
      AND delivery_key = 'once'
  ) THEN
    INSERT INTO public.admin_broadcast_deliveries (
      broadcast_id, user_id, fcm_token, platform, delivery_status, delivery_key
    )
    SELECT broadcast_id, g.user_id, g.fcm_token, g.platform, 'pending', 'once'
    FROM (
      SELECT DISTINCT ON (gu.user_id)
        gu.user_id, gu.fcm_token, gu.platform
      FROM public.get_users_for_broadcast(c) gu
      ORDER BY gu.user_id, gu.fcm_token
    ) g
    ON CONFLICT (broadcast_id, user_id, delivery_key) DO NOTHING;
  END IF;

  FOR target_delivery IN
    SELECT d.id, d.user_id, d.fcm_token, d.platform
    FROM public.admin_broadcast_deliveries d
    WHERE d.broadcast_id = send_admin_broadcast.broadcast_id
      AND d.delivery_key = 'once'
      AND d.delivery_status = 'pending'
    ORDER BY d.id
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_processed := v_processed + 1;

    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_delivery.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= v_freq_limit THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'skipped', failure_reason = 'frequency_guard'
      WHERE id = target_delivery.id;
      CONTINUE;
    END IF;

    BEGIN
      PERFORM public.queue_fcm_notification(
        target_delivery.user_id,
        target_delivery.fcm_token,
        broadcast_record.title,
        broadcast_record.message,
        jsonb_build_object(
          'type', 'admin_broadcast',
          'broadcast_id', broadcast_id,
          'action_url', broadcast_record.action_url,
          'action_url_text', broadcast_record.action_url_text
        ),
        target_delivery.platform
      );

      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'sent',
          sent_at = NOW(),
          failure_reason = NULL
      WHERE id = target_delivery.id;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'failed',
          failure_reason = left(SQLERRM, 500)
      WHERE id = target_delivery.id;
    END;
  END LOOP;

  SELECT
    count(*) FILTER (WHERE delivery_status = 'sent'),
    count(*) FILTER (WHERE delivery_status = 'failed'),
    count(*) FILTER (WHERE delivery_status = 'skipped'),
    count(*) FILTER (WHERE delivery_status = 'pending'),
    count(*)
  INTO v_sent, v_failed, v_skipped, v_pending, v_total
  FROM public.admin_broadcast_deliveries
  WHERE broadcast_id = send_admin_broadcast.broadcast_id
    AND delivery_key = 'once';

  UPDATE public.admin_broadcasts
  SET target_user_count = v_total,
      actual_sent_count = v_sent,
      skipped_count = v_skipped,
      status = CASE
        WHEN v_pending = 0 AND v_sent = 0 THEN 'cancelled'
        WHEN v_pending = 0 THEN 'sent'
        ELSE 'sending'
      END,
      updated_at = NOW()
  WHERE id = broadcast_id;

  RETURN jsonb_build_object(
    'success', true,
    'complete', v_pending = 0,
    'processed_count', v_processed,
    'sent_count', v_sent,
    'failed_count', v_failed,
    'skipped_count', v_skipped,
    'pending_count', v_pending,
    'recipient_total', v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_admin_broadcast(uuid, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Birthday automation: one delivery row per user per year, pending rows
--    are safe to retry, and the configurable frequency cap is applied.
--    (Timezone-aware birthday selection is handled separately.)
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
  v_freq_limit INT;
  v_delivery_id UUID;
  v_year_key TEXT := 'birthday:' || to_char(CURRENT_DATE, 'YYYY');
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

  v_freq_limit := GREATEST(
    public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1
  );

  FOR target_user IN
    SELECT gufb.user_id, gufb.fcm_token, gufb.platform, u.name, u.date_of_birth
    FROM public.get_users_for_broadcast(COALESCE(b.filter_criteria, '{}')) AS gufb
    JOIN public.users u ON u.id = gufb.user_id
    WHERE u.date_of_birth IS NOT NULL
      AND EXTRACT(MONTH FROM u.date_of_birth) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY FROM u.date_of_birth) = EXTRACT(DAY FROM CURRENT_DATE)
    ORDER BY gufb.user_id
    LIMIT 20000
  LOOP
    v_delivery_id := NULL;
    INSERT INTO public.admin_broadcast_deliveries (
      broadcast_id, user_id, fcm_token, platform, delivery_status, delivery_key
    )
    VALUES (
      p_broadcast_id, target_user.user_id, target_user.fcm_token,
      target_user.platform, 'pending', v_year_key
    )
    ON CONFLICT (broadcast_id, user_id, delivery_key) DO NOTHING
    RETURNING id INTO v_delivery_id;

    IF v_delivery_id IS NULL THEN
      CONTINUE;  -- already delivered this year (or queued earlier today)
    END IF;

    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= v_freq_limit THEN
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'skipped', failure_reason = 'frequency_guard'
      WHERE id = v_delivery_id;
      CONTINUE;
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

GRANT EXECUTE ON FUNCTION public.queue_birthday_broadcast_notifications(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Profile reminder automation: same delivery-key discipline + configurable
--    frequency cap (it still hardcoded 2/24h).
-- ---------------------------------------------------------------------------
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
  v_freq_limit INT;
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

  v_freq_limit := GREATEST(
    public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1
  );

  FOR target_user IN
    SELECT * FROM public.claim_profile_reminder_candidates(
      v_offsets, v_repeat, v_max, v_batch
    )
  LOOP
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= v_freq_limit THEN
      CONTINUE;
    END IF;

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

GRANT EXECUTE ON FUNCTION public.queue_profile_reminder_broadcast_notifications(UUID) TO service_role;

COMMIT;
