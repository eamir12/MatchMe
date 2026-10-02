-- Make the per-user admin-broadcast frequency guard configurable.
--
-- The 2/24h cap was hardcoded in three places (send_admin_broadcast,
-- count_target_users, queue_birthday_broadcast_notifications). Now it is read
-- from app_config['notifications.admin_broadcast_max_per_day'] (default 10),
-- so admins can tune it from the Admin "App Config" panel without a migration.
--
-- Applies on top of 20260922000000_fix_admin_broadcast_zero_send.sql.

BEGIN;

-- 1) Generic int reader for app_config (jsonb), mirroring app_config_bool /
--    app_config_jsonb so it tolerates 'number' and 'string' stored values.
CREATE OR REPLACE FUNCTION public.app_config_int(
  p_key text,
  p_default integer
)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN jsonb_typeof(config_value) IN ('number', 'string')
          AND NULLIF(btrim((config_value #>> '{}')), '') ~ '^-?[0-9]+$'
          THEN (config_value #>> '{}')::integer
        ELSE NULL
      END
      FROM public.app_config
      WHERE config_key = p_key
      LIMIT 1
    ),
    p_default
  );
$$;

REVOKE ALL ON FUNCTION public.app_config_int(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.app_config_int(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_config_int(text, integer) TO service_role;

COMMENT ON FUNCTION public.app_config_int(text, integer)
  IS 'Reads an integer from app_config with a fallback default (0 => default).';

-- 2) Seed the config key. Min 1, safe to sanity-check in the Admin UI.
INSERT INTO public.app_config (
  config_key, config_value, config_type, category, description,
  is_user_configurable, min_value, max_value
) VALUES (
  'notifications.admin_broadcast_max_per_day', '10', 'number', 'notifications',
  'Max admin broadcasts a single user can receive per rolling 24h (frequency guard)',
  true, 1, 100
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- 3) send_admin_broadcast: guard reads config (>= cap instead of >= 2).
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
  scanned_count INTEGER := 0;
  skipped_freq INTEGER := 0;
  c JSONB;
  v_issues TEXT[];
  v_limit INT;
  v_offset INT;
  v_freq_limit INT;
BEGIN
  SELECT * INTO broadcast_record FROM public.admin_broadcasts WHERE id = broadcast_id;
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
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_freq_limit := GREATEST(
    public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1
  );

  c := public.normalize_broadcast_filter_criteria(broadcast_record.filter_criteria);

  IF v_offset = 0 THEN
    UPDATE public.admin_broadcasts
    SET status = 'sending',
        sent_at = NOW(),
        filter_criteria = c,
        skipped_count = 0
    WHERE id = broadcast_id;
  END IF;

  FOR target_user IN
    SELECT * FROM public.get_users_for_broadcast(c)
    ORDER BY user_id
    LIMIT v_limit OFFSET v_offset
  LOOP
    scanned_count := scanned_count + 1;

    -- Frequency guard: max admin pushes per user per 24h (app_config):
    -- 'notifications.admin_broadcast_max_per_day' (default 10). Same rule that
    -- count_target_users applies, so confirm and send stay in sync.
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= v_freq_limit THEN
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

  -- Accumulate across chunks.
  UPDATE public.admin_broadcasts
  SET target_user_count = COALESCE(target_user_count, 0) + notification_count,
      actual_sent_count = COALESCE(actual_sent_count, 0) + notification_count,
      skipped_count = COALESCE(skipped_count, 0) + skipped_freq
  WHERE id = broadcast_id;

  -- Final chunk = fewer rows SCANNED than the chunk limit. Only then choose the
  -- terminal status. Zero deliveries (no matches, or all guard-skipped) =>
  -- 'cancelled', never a misleading 'sent'.
  IF scanned_count < v_limit THEN
    IF notification_count = 0 THEN
      UPDATE public.admin_broadcasts
      SET status = 'cancelled'
      WHERE id = broadcast_id;
    ELSE
      UPDATE public.admin_broadcasts
      SET status = 'sent'
      WHERE id = broadcast_id;
    END IF;
  END IF;

  DELETE FROM public.notification_queue
  WHERE created_at < NOW() - INTERVAL '7 days'
    AND status IN ('sent', 'failed');

  RETURN jsonb_build_object(
    'success', true,
    'sent_count', notification_count,
    'scanned_count', scanned_count,
    'skipped_frequency', skipped_freq
  );
END;
$$;

-- 4) count_target_users: apply the same configurable cap.
CREATE OR REPLACE FUNCTION public.count_target_users(filter_criteria jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  user_count integer;
  v_freq_limit INT;
BEGIN
  IF auth.role() = 'service_role' THEN
    v_is_allowed := true;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = true
    ) INTO v_is_allowed;
  END IF;

  IF NOT COALESCE(v_is_allowed, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_freq_limit := GREATEST(
    public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1
  );

  -- Exclude users who already queued <cap> admin broadcasts in the last 24h.
  SELECT COUNT(*)
  INTO user_count
  FROM (
    SELECT g.user_id
    FROM public.get_users_for_broadcast(filter_criteria) g
    WHERE (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = g.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) < v_freq_limit
  ) t;

  RETURN COALESCE(user_count, 0);
END;
$$;

-- 5) Birthday automation: same configurable cap.
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
    -- Frequency guard (same config as send_admin_broadcast).
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= v_freq_limit THEN
      CONTINUE;
    END IF;

    -- Dedup: don't queue same birthday broadcast twice for same user/year.
    IF EXISTS (
      SELECT 1 FROM public.admin_broadcast_deliveries d
      WHERE d.broadcast_id = p_broadcast_id
        AND d.user_id = target_user.user_id
        AND d.created_at >= date_trunc('day', NOW())
    ) THEN
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

    INSERT INTO public.admin_broadcast_deliveries (broadcast_id, user_id, fcm_token)
    VALUES (p_broadcast_id, target_user.user_id, target_user.fcm_token);

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
    v_count := v_count + 1;
  END LOOP;

  UPDATE public.admin_broadcasts
  SET actual_sent_count = COALESCE(actual_sent_count, 0) + v_count,
      updated_at = NOW()
  WHERE id = p_broadcast_id;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_admin_broadcast(uuid, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.count_target_users(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_target_users(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.queue_birthday_broadcast_notifications(UUID) TO service_role;

COMMENT ON FUNCTION public.queue_birthday_broadcast_notifications(UUID)
  IS 'Birthday automation: today birthdays with {first_name}/{name} personalization, limits + configurable frequency guard.';

COMMIT;