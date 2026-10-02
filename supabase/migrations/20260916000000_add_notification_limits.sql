-- Notification limits enforcement (Phase 2).
-- Single source of truth mirrors:
--   supabase/functions/_shared/notification_limits.ts
--   lib/utils/notification_limits.dart
-- FCM/APNs hard cap is 4096 bytes; we enforce a 3500-byte budget
-- with byte-based truncation (Hebrew/Arabic/emoji are multi-byte).

-- 1) Helper: validate admin input, returns issues (empty = OK).
CREATE OR REPLACE FUNCTION public.check_notification_limits(
  p_title TEXT,
  p_body TEXT,
  p_action_url TEXT DEFAULT NULL,
  p_action_url_text TEXT DEFAULT NULL
)
RETURNS TEXT[]
LANGUAGE plpgsql IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_title TEXT := btrim(COALESCE(p_title, ''));
  v_body TEXT := btrim(COALESCE(p_body, ''));
  v_issues TEXT[] := '{}';
BEGIN
  IF v_title = '' THEN
    v_issues := v_issues || 'Title is required';
  END IF;
  IF v_body = '' THEN
    v_issues := v_issues || 'Message is required';
  END IF;
  IF char_length(v_title) > 60 THEN
    v_issues := v_issues || 'Title max 60 chars';
  END IF;
  IF octet_length(v_title) > 200 THEN
    v_issues := v_issues || 'Title max 200 bytes';
  END IF;
  IF char_length(v_body) > 180 THEN
    v_issues := v_issues || 'Message max 180 chars';
  END IF;
  IF octet_length(v_body) > 1000 THEN
    v_issues := v_issues || 'Message max 1000 bytes';
  END IF;
  IF p_action_url_text IS NOT NULL AND char_length(p_action_url_text) > 30 THEN
    v_issues := v_issues || 'Action text max 30 chars';
  END IF;
  IF p_action_url IS NOT NULL AND btrim(p_action_url) <> '' THEN
    IF char_length(p_action_url) > 2000 THEN
      v_issues := v_issues || 'Action URL too long';
    END IF;
    IF p_action_url !~ '^https?://.+\..+' THEN
      v_issues := v_issues || 'Action URL must be http(s)';
    END IF;
  END IF;
  RETURN v_issues;
END;
$$;

-- 2) Helper: byte-safe truncation for queue inserts.
-- Postgres substr() is char-based; loop to respect octet budget.
CREATE OR REPLACE FUNCTION public.truncate_notif_text(p_text TEXT, p_max_bytes INT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v TEXT := COALESCE(p_text, '');
  v_cut TEXT := v;
BEGIN
  IF octet_length(v) <= p_max_bytes THEN
    RETURN v;
  END IF;
  -- Reserve 3 bytes for ellipsis.
  WHILE octet_length(v_cut) > (p_max_bytes - 3) AND char_length(v_cut) > 0 LOOP
    v_cut := substr(v_cut, 1, char_length(v_cut) - 1);
  END LOOP;
  RETURN v_cut || '…';
END;
$$;

-- 3) Clean existing oversize admin drafts so CHECK constraints can be added.
UPDATE public.admin_broadcasts
SET title = public.truncate_notif_text(btrim(title), 200),
    message = public.truncate_notif_text(btrim(message), 1000)
WHERE octet_length(title) > 200
   OR char_length(title) > 60
   OR octet_length(message) > 1000
   OR char_length(message) > 180;

-- 4) Hard CHECKs for admin-authored content.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_broadcast_title_len'
  ) THEN
    ALTER TABLE public.admin_broadcasts
      ADD CONSTRAINT chk_broadcast_title_len
      CHECK (char_length(btrim(title)) <= 60 AND octet_length(title) <= 200);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_broadcast_msg_len'
  ) THEN
    ALTER TABLE public.admin_broadcasts
      ADD CONSTRAINT chk_broadcast_msg_len
      CHECK (char_length(btrim(message)) <= 180 AND octet_length(message) <= 1000);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_broadcast_action_text_len'
  ) THEN
    ALTER TABLE public.admin_broadcasts
      ADD CONSTRAINT chk_broadcast_action_text_len
      CHECK (action_url_text IS NULL OR char_length(action_url_text) <= 30);
  END IF;
END;
$$;

-- 5) Transport guard: auto-truncate anything queued (expiry/match/chat/broadcast).
-- Covers all writers: send_admin_broadcast, cron-jobs, birthday automation.
CREATE OR REPLACE FUNCTION public.trg_truncate_notification_queue()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.title := public.truncate_notif_text(btrim(COALESCE(NEW.title, '')), 500);
  NEW.body := public.truncate_notif_text(btrim(COALESCE(NEW.body, '')), 1500);
  IF NEW.title = '' THEN
    RAISE EXCEPTION 'notification title is required';
  END IF;
  IF NEW.body = '' THEN
    RAISE EXCEPTION 'notification body is required';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_truncate_notification_queue ON public.notification_queue;
CREATE TRIGGER trg_truncate_notification_queue
  BEFORE INSERT OR UPDATE OF title, body ON public.notification_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_truncate_notification_queue();

-- 6) Index for queue polling (status + scheduled_at).
CREATE INDEX IF NOT EXISTS idx_notification_queue_pending_sched
  ON public.notification_queue (status, scheduled_at)
  WHERE status = 'pending';

-- 7) Harden queue_fcm_notification: enforce + truncate + cap data size.
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
  IF octet_length(COALESCE(p_data, '{}')::text) > 2000 THEN
    RAISE EXCEPTION 'notification data exceeds 2000 bytes';
  END IF;
  INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
  ) VALUES (
      p_user_id, btrim(p_fcm_token), v_title, v_body,
      COALESCE(p_data, '{}'), COALESCE(p_platform, 'unknown')
  ) RETURNING id INTO notification_id;
  RETURN notification_id;
END;
$$;

-- 8) Harden send_admin_broadcast: validate, cap fan-out, frequency guard,
-- chunk-friendly (p_limit/p_offset) so 20k blasts don't time out.
-- Drop legacy single-arg VOID overload so all callers hit the guarded version.
DROP FUNCTION IF EXISTS public.send_admin_broadcast(UUID);
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
  target_user RECORD;
  notification_count INTEGER := 0;
  skipped_freq INTEGER := 0;
  c JSONB;
  v_issues TEXT[];
  v_limit INT;
  v_offset INT;
BEGIN
  SELECT * INTO broadcast_record FROM public.admin_broadcasts WHERE id = broadcast_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Broadcast not found';
  END IF;

  -- Hard validation of admin content (mirrors Admin UI + TS helper).
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
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  c := public.normalize_broadcast_filter_criteria(broadcast_record.filter_criteria);

  IF v_offset = 0 THEN
    UPDATE public.admin_broadcasts
    SET status = 'sending', sent_at = NOW(), filter_criteria = c
    WHERE id = broadcast_id;
  END IF;

  FOR target_user IN
    SELECT * FROM public.get_users_for_broadcast(c)
    ORDER BY user_id
    LIMIT v_limit OFFSET v_offset
  LOOP
    -- Frequency guard: max 2 admin pushes per user per day.
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= 2 THEN
      skipped_freq := skipped_freq + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.admin_broadcast_deliveries (broadcast_id, user_id, fcm_token)
    VALUES (broadcast_id, target_user.user_id, target_user.fcm_token);

    PERFORM public.queue_fcm_notification(
        target_user.user_id,
        target_user.fcm_token,
        broadcast_record.title,
        broadcast_record.message,
        jsonb_build_object(
            'type', 'admin_broadcast',
            'broadcast_id', broadcast_id,
            'action_url', broadcast_record.action_url,
            'action_url_text', broadcast_record.action_url_text
        ),
        target_user.platform
    );

    notification_count := notification_count + 1;
  END LOOP;

  -- Only mark sent when this was the final chunk (fewer rows than limit).
  IF notification_count < v_limit THEN
    UPDATE public.admin_broadcasts
    SET target_user_count = COALESCE(target_user_count, 0) + notification_count,
        actual_sent_count = COALESCE(actual_sent_count, 0) + notification_count,
        status = 'sent'
    WHERE id = broadcast_id;
  ELSE
    UPDATE public.admin_broadcasts
    SET target_user_count = COALESCE(target_user_count, 0) + notification_count,
        actual_sent_count = COALESCE(actual_sent_count, 0) + notification_count
    WHERE id = broadcast_id;
  END IF;

  DELETE FROM public.notification_queue
  WHERE created_at < NOW() - INTERVAL '7 days'
    AND status IN ('sent', 'failed');

  RETURN jsonb_build_object(
    'success', true,
    'sent_count', notification_count,
    'skipped_frequency', skipped_freq
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_notification_limits(TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_notification_limits(TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.truncate_notif_text(TEXT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.truncate_notif_text(TEXT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.send_admin_broadcast(UUID, INT, INT) TO service_role;

COMMENT ON FUNCTION public.check_notification_limits(TEXT, TEXT, TEXT, TEXT)
  IS 'Admin hard limits: title 60c/200B, message 180c/1000B, action text 30c. Mirrors TS/Dart helpers.';
