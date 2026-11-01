-- Notification delivery ledger (Batch 1).
--
-- Goals:
--   * One queue row per logical event per device. Every producer keeps its
--     existing insert path; a BEFORE INSERT trigger derives a deterministic
--     event_key from the payload, and a partial unique index
--     (event_key, fcm_token) makes a second copy impossible even under races.
--   * The queue knows what actually happened. 'sent' is written only after
--     the provider accepted the message, together with the provider message
--     id. 'unknown' records an ambiguous outcome (the edge invocation died or
--     the transport threw before a response), and is terminal.
--   * Retry policy (matches how consumer messaging apps treat push):
--       - retry only after an explicit provider rejection: a real HTTP
--         response (429 / 5xx). Those mean FCM/WNS did not accept the send.
--       - never auto-resend after an ambiguous outcome. The in-app inbox
--         still holds the notification and chat content syncs on the next
--         open; silently re-sending here is exactly how duplicate pushes and
--         double buzzes happen.
--       - 'skipped' records a claimed row that was intentionally not sent
--         (recipient already read it, is looking at the chat, or the event
--         expired while the row waited).
--
-- Batch 1 has no intended user-facing change: it only removes duplicate
-- sends and stops retries that may already have reached the device.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Queue ledger columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.notification_queue
  ADD COLUMN IF NOT EXISTS event_key TEXT,
  ADD COLUMN IF NOT EXISTS lease_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS provider_message_id TEXT;

ALTER TABLE public.notification_queue
  DROP CONSTRAINT IF EXISTS notification_queue_status_check;
ALTER TABLE public.notification_queue
  DROP CONSTRAINT IF EXISTS notification_queue_status_check1;
ALTER TABLE public.notification_queue
  ADD CONSTRAINT notification_queue_status_check
  CHECK (status IN ('pending', 'processing', 'sent', 'failed', 'unknown', 'skipped'));

-- One row per logical event per device token. Legacy rows have a NULL
-- event_key and are left untouched.
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_queue_event_device
  ON public.notification_queue (event_key, fcm_token)
  WHERE event_key IS NOT NULL;

-- Stale-claim sweep: only 'processing' rows carry a lease.
CREATE INDEX IF NOT EXISTS idx_notification_queue_lease
  ON public.notification_queue (lease_until)
  WHERE status = 'processing';

-- ---------------------------------------------------------------------------
-- 2) Deterministic event keys.
--
-- Same logical event -> same key, independent of which producer wrote it or
-- how many times a tick re-runs. The recipient is part of the key so a device
-- shared by two test accounts never collapses two users' events.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notification_event_key(
  p_user_id UUID,
  p_data JSONB
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE COALESCE(p_data->>'type', '')
    WHEN 'chat_message' THEN
      NULLIF(
        'chat:' || COALESCE(p_data->>'message_id', p_data->>'messageId', ''),
        'chat:'
      )
    WHEN 'match' THEN
      NULLIF(
        'match:' || COALESCE(p_data->>'match_id', p_data->>'matchId', '')
          || ':' || COALESCE(p_user_id::text, ''),
        'match::'
      )
    WHEN 'new_match' THEN
      NULLIF(
        'match:' || COALESCE(p_data->>'match_id', p_data->>'matchId', '')
          || ':' || COALESCE(p_user_id::text, ''),
        'match::'
      )
    WHEN 'match_expiry' THEN
      NULLIF(
        'match_expiry:' || COALESCE(p_data->>'match_id', p_data->>'matchId', '')
          || ':' || COALESCE(p_user_id::text, '')
          || ':' || COALESCE(p_data->>'threshold_seconds', '')
          || ':' || COALESCE(p_data->>'expiry_at', ''),
        'match_expiry::::'
      )
    WHEN 'pinned_expiry' THEN
      NULLIF(
        'pinned_expiry:' || COALESCE(p_user_id::text, '')
          || ':' || COALESCE(p_data->>'threshold_seconds', '')
          || ':' || COALESCE(p_data->>'expiry_at', ''),
        'pinned_expiry:::'
      )
    WHEN 'match_extended' THEN
      NULLIF(
        'match_extended:' || COALESCE(p_data->>'match_id', p_data->>'matchId', '')
          || ':' || COALESCE(p_user_id::text, ''),
        'match_extended::'
      )
    WHEN 'location_share' THEN
      NULLIF(
        'location_share:' || COALESCE(p_data->>'match_id', p_data->>'matchId', '')
          || ':' || COALESCE(p_user_id::text, '')
          || ':' || COALESCE(p_data->>'expires_at', ''),
        'location_share:::'
      )
    WHEN 'meetup_signal' THEN
      NULLIF(
        'meetup:' || COALESCE(p_data->>'meetup_signal_id', '')
          || ':' || COALESCE(p_user_id::text, ''),
        'meetup::'
      )
    WHEN 'meetup_beacon' THEN
      NULLIF(
        'meetup:' || COALESCE(p_data->>'meetup_signal_id', '')
          || ':' || COALESCE(p_user_id::text, ''),
        'meetup::'
      )
    WHEN 'meetup_spot' THEN
      NULLIF(
        'meetup_spot:' || COALESCE(p_data->>'meetup_spot_id', '')
          || ':' || COALESCE(p_user_id::text, ''),
        'meetup_spot::'
      )
    WHEN 'profile_edit_review' THEN
      NULLIF(
        'profile_edit:' || COALESCE(p_data->>'request_id', '')
          || ':' || COALESCE(p_data->>'decision', ''),
        'profile_edit::'
      )
    WHEN 'admin_broadcast' THEN
      NULLIF(
        'broadcast:' || COALESCE(p_data->>'broadcast_id', '')
          || ':' || COALESCE(NULLIF(p_data->>'delivery_key', ''), 'once')
          || ':' || COALESCE(p_user_id::text, ''),
        'broadcast::once:'
      )
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION public.notification_event_key(UUID, JSONB)
  IS 'Deterministic per-event key for notification_queue dedupe (event_key, fcm_token).';

-- ---------------------------------------------------------------------------
-- 3) Stamp the key and drop accidental re-enqueues before they insert.
--
-- Returning NULL skips the INSERT, so the capture trigger never writes a
-- second inbox row either. The unique index above is the race backstop; the
-- admin-broadcast funnel and the push-message chat retry path additionally
-- use ON CONFLICT DO NOTHING, and the expiry scans treat 23505 as "already
-- queued".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_notification_queue_ledger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.event_key IS NULL OR btrim(NEW.event_key) = '' THEN
    NEW.event_key := public.notification_event_key(NEW.user_id, NEW.data);
  END IF;

  IF NEW.event_key IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.notification_queue q
      WHERE q.event_key = NEW.event_key
        AND q.fcm_token = NEW.fcm_token
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notification_queue_ledger ON public.notification_queue;
CREATE TRIGGER trg_notification_queue_ledger
  BEFORE INSERT ON public.notification_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_notification_queue_ledger();

-- ---------------------------------------------------------------------------
-- 4) Stale claims become 'unknown', never 'pending'.
--
-- A 'processing' row whose lease expired may or may not have reached FCM.
-- Requeueing it is the duplicate-send bug; the sweep records the ambiguity
-- and stops. The in-app inbox still carries the notification.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.requeue_stale_notification_queue(INT);

CREATE OR REPLACE FUNCTION public.requeue_stale_notification_queue(
  p_min_age_minutes INT DEFAULT 15
)
RETURNS TABLE (requeued INT, failed INT, unknown_count INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unknown INT := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 1 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 1';
  END IF;

  WITH recovered AS (
    UPDATE public.notification_queue q
    SET status = 'unknown',
        failure_reason = COALESCE(
          q.failure_reason,
          'ambiguous: send outcome unknown (claim expired); not retried'
        ),
        lease_until = NULL,
        updated_at = now()
    WHERE q.status = 'processing'
      AND COALESCE(q.lease_until, q.updated_at, q.created_at)
          < now() - make_interval(mins => p_min_age_minutes)
    RETURNING q.id
  )
  SELECT COUNT(*)::int INTO v_unknown FROM recovered;

  requeued := 0;
  failed := 0;
  unknown_count := COALESCE(v_unknown, 0);
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.requeue_stale_notification_queue(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.requeue_stale_notification_queue(INT)
  TO service_role;

-- Bounded retention for terminal rows. Called by the existing cron queue
-- task, so no new schedule is introduced. 7 days matches the FCM TTL: after
-- that a queued row could not be delivered anyway, and event keys are free to
-- be reused by a genuinely new event with the same identity.
CREATE OR REPLACE FUNCTION public.prune_notification_queue(
  p_keep_days INT DEFAULT 7,
  p_limit INT DEFAULT 2000
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  WITH doomed AS (
    SELECT id
    FROM public.notification_queue
    WHERE status IN ('sent', 'failed', 'unknown', 'skipped')
      AND created_at < now() - make_interval(days => GREATEST(COALESCE(p_keep_days, 7), 1))
    ORDER BY created_at
    LIMIT GREATEST(COALESCE(p_limit, 2000), 1)
  )
  DELETE FROM public.notification_queue q
  USING doomed d
  WHERE q.id = d.id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_notification_queue(INT, INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_notification_queue(INT, INT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Inbox dedupe for the three types that could duplicate per device.
-- ---------------------------------------------------------------------------
DELETE FROM public.user_notifications a
USING public.user_notifications b
WHERE a.id > b.id
  AND a.user_id = b.user_id
  AND a.type = 'location_share'
  AND b.type = 'location_share'
  AND COALESCE(a.data->>'match_id', a.data->>'matchId', '') =
      COALESCE(b.data->>'match_id', b.data->>'matchId', '')
  AND COALESCE(a.data->>'expires_at', '') = COALESCE(b.data->>'expires_at', '');

DELETE FROM public.user_notifications a
USING public.user_notifications b
WHERE a.id > b.id
  AND a.user_id = b.user_id
  AND a.type = 'match_extended'
  AND b.type = 'match_extended'
  AND COALESCE(a.data->>'match_id', a.data->>'matchId', '') =
      COALESCE(b.data->>'match_id', b.data->>'matchId', '')
  AND COALESCE(a.data->>'expires_at', '') = COALESCE(b.data->>'expires_at', '');

DELETE FROM public.user_notifications a
USING public.user_notifications b
WHERE a.id > b.id
  AND a.user_id = b.user_id
  AND a.type = 'profile_edit_review'
  AND b.type = 'profile_edit_review'
  AND COALESCE(a.data->>'request_id', '') <> ''
  AND COALESCE(a.data->>'request_id', '') = COALESCE(b.data->>'request_id', '')
  AND COALESCE(a.data->>'decision', '') = COALESCE(b.data->>'decision', '');

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_notifications_location_share_dedupe
  ON public.user_notifications (
    user_id,
    (COALESCE(data->>'match_id', data->>'matchId', '')),
    (COALESCE(data->>'expires_at', ''))
  )
  WHERE type = 'location_share';

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_notifications_match_extended_dedupe
  ON public.user_notifications (
    user_id,
    (COALESCE(data->>'match_id', data->>'matchId', '')),
    (COALESCE(data->>'expires_at', ''))
  )
  WHERE type = 'match_extended';

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_notifications_profile_edit_dedupe
  ON public.user_notifications (
    user_id,
    (COALESCE(data->>'request_id', '')),
    (COALESCE(data->>'decision', ''))
  )
  WHERE type = 'profile_edit_review' AND COALESCE(data->>'request_id', '') <> '';

-- Keep the BEFORE INSERT dedupe trigger in sync with the indexes above so a
-- direct writer (push disabled / no token) cannot raise a unique violation
-- that would abort its notification function.
CREATE OR REPLACE FUNCTION public.trg_user_notifications_dedupe()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id TEXT;
  v_match_id TEXT;
  v_threshold TEXT;
  v_expiry_at TEXT;
  v_signal_id TEXT;
  v_spot_id TEXT;
  v_request_id TEXT;
  v_decision TEXT;
BEGIN
  v_message_id := COALESCE(NEW.data->>'message_id', '');
  v_match_id := COALESCE(NEW.data->>'match_id', COALESCE(NEW.data->>'matchId', ''));
  v_signal_id := COALESCE(NEW.data->>'meetup_signal_id', '');
  v_spot_id := COALESCE(NEW.data->>'meetup_spot_id', '');

  IF v_message_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'message_id' = v_message_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_match_id <> '' AND NEW.type IN ('match', 'new_match') THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type IN ('match', 'new_match')
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  v_threshold := COALESCE(NEW.data->>'threshold_seconds', '');
  v_expiry_at := COALESCE(NEW.data->>'expiry_at', '');

  IF NEW.type = 'match_expiry' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'match_expiry'
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
        AND COALESCE(un.data->>'threshold_seconds', '') = v_threshold
        AND COALESCE(un.data->>'expiry_at', '') = v_expiry_at
    ) THEN
      RETURN NULL;
    END IF;
  ELSIF NEW.type = 'pinned_expiry' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'pinned_expiry'
        AND COALESCE(un.data->>'threshold_seconds', '') = v_threshold
        AND COALESCE(un.data->>'expiry_at', '') = v_expiry_at
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_signal_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'meetup_signal_id' = v_signal_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_spot_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.data->>'meetup_spot_id' = v_spot_id
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF NEW.type = 'location_share' AND v_match_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'location_share'
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
        AND COALESCE(un.data->>'expires_at', '') = COALESCE(NEW.data->>'expires_at', '')
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF NEW.type = 'match_extended' AND v_match_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.user_notifications un
      WHERE un.user_id = NEW.user_id
        AND un.type = 'match_extended'
        AND COALESCE(un.data->>'match_id', un.data->>'matchId', '') = v_match_id
        AND COALESCE(un.data->>'expires_at', '') = COALESCE(NEW.data->>'expires_at', '')
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  IF NEW.type = 'profile_edit_review' THEN
    v_request_id := COALESCE(NEW.data->>'request_id', '');
    v_decision := COALESCE(NEW.data->>'decision', '');
    IF v_request_id <> '' THEN
      IF EXISTS (
        SELECT 1 FROM public.user_notifications un
        WHERE un.user_id = NEW.user_id
          AND un.type = 'profile_edit_review'
          AND COALESCE(un.data->>'request_id', '') = v_request_id
          AND COALESCE(un.data->>'decision', '') = v_decision
      ) THEN
        RETURN NULL;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6) Admin broadcast funnel: a duplicate enqueue must not surface as an
--    error (the delivery snapshot can be re-processed after a crash between
--    the queue insert and the delivery update).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_fcm_notification(
  p_user_id UUID,
  p_fcm_token TEXT,
  p_title TEXT,
  p_body TEXT,
  p_data JSONB DEFAULT '{}',
  p_platform TEXT DEFAULT 'unknown'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  notification_id UUID;
  v_title TEXT;
  v_body TEXT;
  v_data JSONB;
  v_prefs JSONB;
  v_sound BOOLEAN;
  v_vibrate BOOLEAN;
BEGIN
  IF p_fcm_token IS NULL OR btrim(p_fcm_token) = '' THEN
    RAISE EXCEPTION 'fcm_token is required';
  END IF;
  v_title := public.truncate_notif_text(btrim(COALESCE(p_title, '')), 500);
  v_body := public.truncate_notif_text(btrim(COALESCE(p_body, '')), 1500);
  IF v_title = '' THEN
    RAISE EXCEPTION 'notification title is required';
  END IF;
  IF v_body = '' THEN
    RAISE EXCEPTION 'notification body is required';
  END IF;

  v_data := COALESCE(p_data, '{}'::jsonb);

  -- Admin broadcasts: carry the user's sound/vibration preference to the sender
  -- so the FCM message targets the matching Android channel.
  IF COALESCE(v_data->>'type', '') = 'admin_broadcast'
     AND NOT (v_data ? 'channel_id') THEN
    SELECT u.notification_preferences
    INTO v_prefs
    FROM public.users u
    WHERE u.id = p_user_id;

    SELECT f.sound_enabled, f.vibrate_enabled
    INTO v_sound, v_vibrate
    FROM public.admin_broadcast_alert_prefs(v_prefs) f;

    v_data := v_data || jsonb_build_object(
      'sound', CASE WHEN COALESCE(v_sound, true) THEN 'true' ELSE 'false' END,
      'vibrate', CASE WHEN COALESCE(v_vibrate, true) THEN 'true' ELSE 'false' END,
      'channel_id', public.admin_broadcast_channel_id(v_sound, v_vibrate)
    );
  END IF;

  IF octet_length(v_data::text) > 2000 THEN
    RAISE EXCEPTION 'notification data exceeds 2000 bytes';
  END IF;

  INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
  ) VALUES (
      p_user_id, btrim(p_fcm_token), v_title, v_body,
      v_data, COALESCE(p_platform, 'unknown')
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO notification_id;
  RETURN notification_id;
END;
$$;

COMMENT ON FUNCTION public.queue_fcm_notification(UUID, TEXT, TEXT, TEXT, JSONB, TEXT)
  IS 'Inserts a queue row (deduped by the ledger trigger); admin_broadcast rows gain sound/vibrate/channel_id from the recipient preferences.';

-- ---------------------------------------------------------------------------
-- 7) Broadcast delivery ledger: 'queued' at enqueue, 'sent' only when the
--    provider accepted. 'once'/'birthday:YYYY'/'reminder:YYYY-MM-DD' rides in
--    the payload so the drainer updates the exact delivery row.
-- ---------------------------------------------------------------------------
ALTER TABLE public.admin_broadcast_deliveries
  DROP CONSTRAINT IF EXISTS admin_broadcast_deliveries_delivery_status_check;

ALTER TABLE public.admin_broadcast_deliveries
  ADD CONSTRAINT admin_broadcast_deliveries_delivery_status_check
  CHECK (delivery_status IN ('pending', 'queued', 'sent', 'skipped', 'delivered', 'failed'));

-- The parameter is renamed p_broadcast_id: the old name shadowed the
-- broadcast_id column and made every SQL statement that referenced it
-- ambiguous ("column reference broadcast_id is ambiguous"), so the function
-- could not send at all.
DROP FUNCTION IF EXISTS public.send_admin_broadcast(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.send_admin_broadcast(
  p_broadcast_id UUID,
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
  v_queued INT := 0;
  v_failed INT := 0;
  v_skipped INT := 0;
  v_pending INT := 0;
  v_total INT := 0;
  v_processed INT := 0;
BEGIN
  -- Serialise concurrent invocations for the same broadcast.
  SELECT * INTO broadcast_record
  FROM public.admin_broadcasts
  WHERE id = p_broadcast_id
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
    WHERE id = p_broadcast_id;
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
    WHERE id = p_broadcast_id;
  END IF;

  -- Snapshot the audience exactly once. DISTINCT ON collapses users with
  -- several live sessions to one push; ON CONFLICT makes a re-entry a no-op.
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_broadcast_deliveries d
    WHERE d.broadcast_id = p_broadcast_id
      AND d.delivery_key = 'once'
  ) THEN
    INSERT INTO public.admin_broadcast_deliveries (
      broadcast_id, user_id, fcm_token, platform, delivery_status, delivery_key
    )
    SELECT p_broadcast_id, g.user_id, g.fcm_token, g.platform, 'pending', 'once'
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
    WHERE d.broadcast_id = p_broadcast_id
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
          'broadcast_id', p_broadcast_id,
          'delivery_key', 'once',
          'action_url', broadcast_record.action_url,
          'action_url_text', broadcast_record.action_url_text
        ),
        target_delivery.platform
      );

      -- The push is only queued here. The drainer flips this to 'sent' when
      -- FCM accepts the message (or 'failed' on a definitive rejection).
      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'queued',
          sent_at = NULL,
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
    count(*) FILTER (WHERE delivery_status = 'queued'),
    count(*)
  INTO v_sent, v_failed, v_skipped, v_pending, v_queued, v_total
  FROM public.admin_broadcast_deliveries d
  WHERE d.broadcast_id = p_broadcast_id
    AND d.delivery_key = 'once';

  UPDATE public.admin_broadcasts
  SET target_user_count = v_total,
      actual_sent_count = v_sent + v_queued,
      skipped_count = v_skipped,
      status = CASE
        WHEN v_pending = 0 AND v_queued = 0 AND v_sent = 0 THEN 'cancelled'
        WHEN v_pending = 0 AND v_queued = 0 THEN 'sent'
        ELSE 'sending'
      END,
      updated_at = NOW()
  WHERE id = p_broadcast_id;

  RETURN jsonb_build_object(
    'success', true,
    'complete', v_pending = 0 AND v_queued = 0,
    'processed_count', v_processed,
    'sent_count', v_sent,
    'queued_count', v_queued,
    'failed_count', v_failed,
    'skipped_count', v_skipped,
    'pending_count', v_pending,
    'recipient_total', v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_admin_broadcast(uuid, integer, integer) TO service_role;

-- Admin stats treat 'queued' as still in flight, so a broadcast mid-flight
-- shows a coherent total instead of "sent 0, pending 0".
CREATE OR REPLACE FUNCTION public.get_broadcast_stats(p_broadcast_id uuid)
RETURNS TABLE(total_target integer, sent_count integer, delivered_count integer, failed_count integer, pending_count integer, delivery_rate numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT COUNT(*)::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'sent')::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'delivered')::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'failed')::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status IN ('pending', 'queued'))::integer,
    ROUND((COUNT(*) FILTER (WHERE abd.delivery_status = 'delivered')::numeric / NULLIF(COUNT(*),0) * 100),2)
  FROM public.admin_broadcast_deliveries abd WHERE abd.broadcast_id = p_broadcast_id;
END;
$$;

REVOKE ALL ON FUNCTION public.get_broadcast_stats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broadcast_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_broadcast_stats(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) Birthday automation: same ledger semantics.
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
          'delivery_key', v_delivery_key,
          'action_url', NULLIF(v_action_url, ''),
          'action_url_text', NULLIF(v_action_text, '')
        ),
        target_user.platform
      );

      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'queued', sent_at = NULL, failure_reason = NULL
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
-- 9) Profile reminder automation: same ledger semantics.
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
          'delivery_key', v_day_key,
          'action_url', NULLIF(v_action_url, ''),
          'action_url_text', NULLIF(v_action_text, '')
        ),
        target_user.platform
      );

      UPDATE public.admin_broadcast_deliveries
      SET delivery_status = 'queued', sent_at = NULL, failure_reason = NULL
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

-- ---------------------------------------------------------------------------
-- 10) Health payload: surface the new terminal states.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_notification_queue_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pending INT;
  v_processing INT;
  v_failed_1h INT;
  v_sent_1h INT;
  v_unknown_24h INT;
  v_skipped_24h INT;
  v_oldest_pending TIMESTAMPTZ;
  v_oldest_age_sec INT;
BEGIN
  IF auth.role() <> 'service_role' THEN
    IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) THEN
      RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
    END IF;
  END IF;
  SELECT COUNT(*) INTO v_pending FROM public.notification_queue WHERE status = 'pending';
  SELECT COUNT(*) INTO v_processing FROM public.notification_queue WHERE status = 'processing';
  SELECT COUNT(*) INTO v_failed_1h FROM public.notification_queue
    WHERE status = 'failed' AND updated_at >= NOW() - INTERVAL '1 hour';
  SELECT COUNT(*) INTO v_sent_1h FROM public.notification_queue
    WHERE status = 'sent' AND sent_at >= NOW() - INTERVAL '1 hour';
  SELECT COUNT(*) INTO v_unknown_24h FROM public.notification_queue
    WHERE status = 'unknown' AND updated_at >= NOW() - INTERVAL '24 hours';
  SELECT COUNT(*) INTO v_skipped_24h FROM public.notification_queue
    WHERE status = 'skipped' AND updated_at >= NOW() - INTERVAL '24 hours';
  SELECT MIN(created_at) INTO v_oldest_pending FROM public.notification_queue WHERE status = 'pending';
  IF v_oldest_pending IS NULL THEN
    v_oldest_age_sec := 0;
  ELSE
    v_oldest_age_sec := EXTRACT(EPOCH FROM (NOW() - v_oldest_pending))::INT;
  END IF;

  RETURN jsonb_build_object(
    'pending', COALESCE(v_pending, 0),
    'processing', COALESCE(v_processing, 0),
    'failed_last_hour', COALESCE(v_failed_1h, 0),
    'sent_last_hour', COALESCE(v_sent_1h, 0),
    'unknown_last_24h', COALESCE(v_unknown_24h, 0),
    'skipped_last_24h', COALESCE(v_skipped_24h, 0),
    'oldest_pending_at', v_oldest_pending,
    'oldest_pending_age_sec', v_oldest_age_sec,
    -- Alert when backlog grows or oldest waits too long (sender stuck).
    'alert', (
      COALESCE(v_pending, 0) > 1000
      OR v_oldest_age_sec > 600
      OR COALESCE(v_failed_1h, 0) > 50
      OR COALESCE(v_unknown_24h, 0) > 50
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_notification_queue_health() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_notification_queue_health() TO authenticated;

COMMENT ON FUNCTION public.get_notification_queue_health()
  IS 'Queue health: pending/processing/failed/sent/unknown/skipped + alert flag.';

NOTIFY pgrst, 'reload schema';

COMMIT;
