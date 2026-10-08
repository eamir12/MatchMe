BEGIN;
-- Migration: Profile reminder as a first-class admin broadcast automation
-- Date: 2026-10-06
-- Depends on: 20262095000000 (claim_profile_reminder_candidates + config)
--
-- Converts the automatic "complete your profile" reminder from the
-- config-only cron task into the SAME shape as the birthday automation:
--
--   - The reminder lives as an admin_broadcasts row with
--     automation_type = 'profile_reminder' and automation_enabled toggle.
--     Admins edit its title/message/action URL (+ {first_name}/{name}
--     personalization placeholders) in the regular broadcasts composer.
--   - cron-jobs loops over enabled profile_reminder rows and calls
--     queue_profile_reminder_broadcast_notifications(), which claims due
--     users via claim_profile_reminder_candidates() (incomplete profile,
--     app closed per the configured 1h/5h/24h intervals, stage-tracked in
--     profile_reminder_state), then personalizes, records an
--     admin_broadcast_deliveries row (so delivery stats work), and queues
--     the push through queue_fcm_notification.
--
-- One row is seeded (idempotent) so the automation exists immediately; its
-- text is editable in the admin UI afterwards.
--
-- Notes:
--   - The broadcast's filter_criteria is deliberately NOT applied: reminder
--     eligibility is fully determined by the claim function (incomplete
--     profile, reachable, app closed). Keep filter_criteria empty.
--   - The 2/day admin_broadcast frequency guard can skip a just-claimed user
--     (e.g. a manual broadcast went out the same day); that user simply
--     waits for the next stage instead of being re-sent the current one.
--   - app_config notifications.profile_reminder.* still controls intervals;
--     the .enabled key remains a global kill switch on top of the
--     per-broadcast toggle in the admin UI.


-- 0) The automation_type CHECK constraint was added out-of-band (not in any
--    repo migration) and only whitelisted 'birthday'. Extend it to allow
--    'profile_reminder' before inserting the seeded automation row.
ALTER TABLE public.admin_broadcasts
  DROP CONSTRAINT IF EXISTS admin_broadcasts_automation_type_check;
ALTER TABLE public.admin_broadcasts
  ADD CONSTRAINT admin_broadcasts_automation_type_check
  CHECK (
    automation_type IS NULL
    OR automation_type = ANY (ARRAY['birthday'::text, 'profile_reminder'::text])
  );

-- 1) Birthday-style queue function for profile reminders.
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
  v_offsets double precision[] := ARRAY[1.0, 5.0]::double precision[];
  v_repeat double precision := 24;
  v_max integer := 0;
  v_batch integer := 200;
  v_cfg jsonb;
  v_enabled_cfg boolean;
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
    -- 2/day frequency guard (same as send_admin_broadcast / birthday).
    IF (
      SELECT COUNT(*) FROM public.notification_queue q
      WHERE q.user_id = target_user.user_id
        AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) >= 2 THEN
      CONTINUE;
    END IF;

    -- Defensive per-day dedupe (claim already prevents same-stage re-sends).
    IF EXISTS (
      SELECT 1 FROM public.admin_broadcast_deliveries d
      WHERE d.broadcast_id = p_broadcast_id
        AND d.user_id = target_user.user_id
        AND d.created_at >= date_trunc('day', NOW())
    ) THEN
      CONTINUE;
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

GRANT EXECUTE ON FUNCTION public.queue_profile_reminder_broadcast_notifications(UUID) TO service_role;

COMMENT ON FUNCTION public.queue_profile_reminder_broadcast_notifications(UUID)
  IS 'Profile reminder automation: incomplete profiles closed for the configured intervals, {first_name}/{name} personalization, limits + frequency guard.';

-- 2) Seed the automation row (idempotent). Status 'draft' keeps it editable
--    in the composer; automation_enabled makes it live immediately.
INSERT INTO public.admin_broadcasts
  (title, message, message_type, automation_type, automation_enabled, status, filter_criteria, created_at, updated_at)
SELECT
  'Finish your profile',
  'Hi {first_name}! Your profile is almost ready — finish it now so people can find you and match with you.',
  'info', 'profile_reminder', true, 'draft', '{}'::jsonb, NOW(), NOW()
WHERE NOT EXISTS (
  SELECT 1 FROM public.admin_broadcasts WHERE automation_type = 'profile_reminder'
);


ROLLBACK;
