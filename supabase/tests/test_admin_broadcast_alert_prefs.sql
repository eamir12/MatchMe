-- supabase/tests/test_admin_broadcast_alert_prefs.sql
-- Verifies the admin-announcement alert-preference helpers that pick the Android
-- channel for FCM admin broadcasts (migration
-- 20260925000000_admin_broadcast_alert_preferences.sql). Exits with an error on
-- any mismatch, so it can be run directly in the SQL editor / CI.

DO $$
DECLARE
  r RECORD;
  v_user uuid;
  v_queue_id uuid;
  v_data jsonb;
BEGIN
  -- 1) Channel mapping must mirror AdminBroadcastChannels.idFor().
  IF public.admin_broadcast_channel_id(true, true) <> 'admin_broadcasts' THEN
    RAISE EXCEPTION 'channel(true,true) expected admin_broadcasts, got %',
      public.admin_broadcast_channel_id(true, true);
  END IF;
  IF public.admin_broadcast_channel_id(true, false) <> 'admin_broadcasts_sound' THEN
    RAISE EXCEPTION 'channel(true,false) expected admin_broadcasts_sound, got %',
      public.admin_broadcast_channel_id(true, false);
  END IF;
  IF public.admin_broadcast_channel_id(false, true) <> 'admin_broadcasts_vibrate' THEN
    RAISE EXCEPTION 'channel(false,true) expected admin_broadcasts_vibrate, got %',
      public.admin_broadcast_channel_id(false, true);
  END IF;
  IF public.admin_broadcast_channel_id(false, false) <> 'admin_broadcasts_silent' THEN
    RAISE EXCEPTION 'channel(false,false) expected admin_broadcasts_silent, got %',
      public.admin_broadcast_channel_id(false, false);
  END IF;
  -- Unset values default to the alerting channel.
  IF public.admin_broadcast_channel_id(NULL, NULL) <> 'admin_broadcasts' THEN
    RAISE EXCEPTION 'channel(NULL,NULL) expected admin_broadcasts, got %',
      public.admin_broadcast_channel_id(NULL, NULL);
  END IF;

  -- 2) NULL prefs => sound + vibrate enabled (Dart defaults).
  SELECT * INTO r FROM public.admin_broadcast_alert_prefs(NULL);
  IF r.sound_enabled IS DISTINCT FROM true
     OR r.vibrate_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'NULL prefs must default to sound+vibrate enabled (got sound=%, vibrate=%)',
      r.sound_enabled, r.vibrate_enabled;
  END IF;

  -- 3) Per-type opt-out for admin announcements only.
  SELECT * INTO r FROM public.admin_broadcast_alert_prefs(
    '{"schema_version":2,
      "global_methods":{"push":true,"in_app":true,"sound":true,"vibrate":true},
      "matrix":{"admin_announcements":{"push":true,"in_app":true,"sound":false,"vibrate":false}}}'::jsonb);
  IF r.sound_enabled IS DISTINCT FROM false
     OR r.vibrate_enabled IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'matrix admin_announcements sound/vibrate=false must disable both (got sound=%, vibrate=%)',
      r.sound_enabled, r.vibrate_enabled;
  END IF;

  -- 4) A global opt-out wins over an enabled per-type entry.
  SELECT * INTO r FROM public.admin_broadcast_alert_prefs(
    '{"global_methods":{"sound":false,"vibrate":false},
      "matrix":{"admin_announcements":{"sound":true,"vibrate":true}}}'::jsonb);
  IF r.sound_enabled IS DISTINCT FROM false
     OR r.vibrate_enabled IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'global sound/vibrate=false must disable both (got sound=%, vibrate=%)',
      r.sound_enabled, r.vibrate_enabled;
  END IF;

  -- 5) Legacy global keys are honoured when global_methods is absent.
  SELECT * INTO r FROM public.admin_broadcast_alert_prefs(
    '{"enable_sound":false,"enable_vibration":true}'::jsonb);
  IF r.sound_enabled IS DISTINCT FROM false
     OR r.vibrate_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'legacy enable_sound/enable_vibration must be honoured (got sound=%, vibrate=%)',
      r.sound_enabled, r.vibrate_enabled;
  END IF;

  -- 6) Mixed preference maps to the sound-only channel.
  SELECT * INTO r FROM public.admin_broadcast_alert_prefs(
    '{"global_methods":{"sound":true,"vibrate":false},"matrix":{}}'::jsonb);
  IF public.admin_broadcast_channel_id(r.sound_enabled, r.vibrate_enabled)
     <> 'admin_broadcasts_sound' THEN
    RAISE EXCEPTION 'sound-only preference must map to admin_broadcasts_sound';
  END IF;

  -- 7) queue_fcm_notification must stamp admin_broadcast rows with sound,
  --    vibrate and channel_id (the funnel used by every admin producer).
  SELECT id INTO v_user FROM public.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'no users present - skipping enqueue assertion';
  ELSE
    v_queue_id := public.queue_fcm_notification(
      v_user,
      'TEST_TOKEN_ADMIN_ALERT_PREFS',
      'alert prefs test',
      'alert prefs test body',
      jsonb_build_object('type', 'admin_broadcast', 'broadcast_id', gen_random_uuid()),
      'android'
    );

    SELECT data INTO v_data FROM public.notification_queue WHERE id = v_queue_id;

    IF NOT (v_data ? 'sound') OR NOT (v_data ? 'vibrate') OR NOT (v_data ? 'channel_id') THEN
      RAISE EXCEPTION 'admin_broadcast queue row missing alert keys: %', v_data;
    END IF;
    IF v_data->>'channel_id' <> public.admin_broadcast_channel_id(
        (v_data->>'sound')::boolean, (v_data->>'vibrate')::boolean) THEN
      RAISE EXCEPTION 'queue channel_id % does not match its sound/vibrate flags %',
        v_data->>'channel_id', v_data;
    END IF;

    DELETE FROM public.notification_queue WHERE id = v_queue_id;

    -- Non-admin rows must stay untouched.
    v_queue_id := public.queue_fcm_notification(
      v_user,
      'TEST_TOKEN_ADMIN_ALERT_PREFS',
      'chat test',
      'chat test body',
      jsonb_build_object('type', 'chat_message'),
      'android'
    );
    SELECT data INTO v_data FROM public.notification_queue WHERE id = v_queue_id;
    IF v_data ? 'channel_id' OR v_data ? 'sound' OR v_data ? 'vibrate' THEN
      RAISE EXCEPTION 'non-admin queue row must not gain alert keys: %', v_data;
    END IF;
    DELETE FROM public.notification_queue WHERE id = v_queue_id;
  END IF;
END
$$;

-- If we reach here, test passed
SELECT 'ok' AS test_status;
