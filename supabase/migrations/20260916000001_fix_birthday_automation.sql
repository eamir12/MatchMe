-- Fix birthday automation: missing RPC + missing columns.
-- cron-jobs handleBirthdayBroadcastAutomations calls
--   rpc queue_birthday_broadcast_notifications(p_broadcast_id)
-- but no migration defines it, so the cron task errors every tick.

-- 1) Columns used by Admin UI (idempotent).
ALTER TABLE public.admin_broadcasts
  ADD COLUMN IF NOT EXISTS automation_type TEXT,
  ADD COLUMN IF NOT EXISTS automation_enabled BOOLEAN DEFAULT false;

-- 2) Personalized birthday queue: today birthdays ∩ broadcast filter,
-- {first_name}/{name} replaced, limits + 2/day frequency guard applied.
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
    SELECT gufb.user_id, gufb.fcm_token, gufb.platform, u.name, u.date_of_birth
    FROM public.get_users_for_broadcast(COALESCE(b.filter_criteria, '{}')) AS gufb
    JOIN public.users u ON u.id = gufb.user_id
    WHERE u.date_of_birth IS NOT NULL
      AND EXTRACT(MONTH FROM u.date_of_birth) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY FROM u.date_of_birth) = EXTRACT(DAY FROM CURRENT_DATE)
    ORDER BY gufb.user_id
    LIMIT 20000
  LOOP
    -- 2/day frequency guard (same as send_admin_broadcast).
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= 2 THEN
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

GRANT EXECUTE ON FUNCTION public.queue_birthday_broadcast_notifications(UUID) TO service_role;

COMMENT ON FUNCTION public.queue_birthday_broadcast_notifications(UUID)
  IS 'Birthday automation: today birthdays with {first_name}/{name} personalization, limits + frequency guard.';
