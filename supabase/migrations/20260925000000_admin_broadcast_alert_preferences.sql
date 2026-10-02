-- Respect the recipient's in-app "Admin announcements" sound / vibration
-- preference for admin broadcasts — including the FCM/OS-drawn tray entry that
-- is the ONLY entry shown while the app is backgrounded or killed.
--
-- Why a channel: Android 8+ (API 26+) takes a notification's sound and
-- vibration from its CHANNEL, not from per-notification flags, and a channel's
-- sound/vibration can never be changed after creation. The sender can therefore
-- only honour `matrix.admin_announcements.sound|vibrate` by targeting a channel
-- whose settings match:
--
--   sound + vibrate -> admin_broadcasts          (alerting, existing id)
--   sound only      -> admin_broadcasts_sound
--   vibrate only    -> admin_broadcasts_vibrate
--   neither         -> admin_broadcasts_silent
--
-- Ids MUST stay in sync with lib/utils/notification_channels.dart
-- (AdminBroadcastChannels), which pre-creates all four on the device.
--
-- Resolution mirrors the Dart model:
--   NotificationPreferencesState.isMethodEnabled(adminAnnouncements, sound)
--     = global_methods[sound] (default true) AND matrix.admin_announcements[sound]
--       (default true), with the legacy `enable_sound` / `enable_vibration`
--       keys as a fallback for the global gate.

BEGIN;

-- 1) Tolerant jsonb->boolean reader (mirrors app_config_bool tolerances).
CREATE OR REPLACE FUNCTION public.mm_jsonb_bool(
  p_value jsonb,
  p_default boolean
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_value IS NULL THEN p_default
    WHEN jsonb_typeof(p_value) = 'boolean' THEN (p_value #>> '{}')::boolean
    WHEN jsonb_typeof(p_value) = 'string'
      AND lower(btrim(p_value #>> '{}')) IN ('true', 'false', 't', 'f', '1', '0')
      THEN lower(btrim(p_value #>> '{}')) IN ('true', 't', '1')
    ELSE p_default
  END;
$$;

REVOKE ALL ON FUNCTION public.mm_jsonb_bool(jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mm_jsonb_bool(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_jsonb_bool(jsonb, boolean) TO service_role;

-- 2) Effective admin-announcement alert preference for a notification_preferences
--    blob. NULL / missing / malformed values default to "enabled", matching the
--    Dart defaults.
CREATE OR REPLACE FUNCTION public.admin_broadcast_alert_prefs(p_prefs jsonb)
RETURNS TABLE(sound_enabled boolean, vibrate_enabled boolean)
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT
    public.mm_jsonb_bool(
      p_prefs->'global_methods'->'sound',
      public.mm_jsonb_bool(p_prefs->'enable_sound', true)
    )
      AND public.mm_jsonb_bool(
        p_prefs->'matrix'->'admin_announcements'->'sound', true
      ),
    public.mm_jsonb_bool(
      p_prefs->'global_methods'->'vibrate',
      public.mm_jsonb_bool(p_prefs->'enable_vibration', true)
    )
      AND public.mm_jsonb_bool(
        p_prefs->'matrix'->'admin_announcements'->'vibrate', true
      );
$$;

REVOKE ALL ON FUNCTION public.admin_broadcast_alert_prefs(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_broadcast_alert_prefs(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_broadcast_alert_prefs(jsonb) TO service_role;

COMMENT ON FUNCTION public.admin_broadcast_alert_prefs(jsonb)
  IS 'Effective sound/vibrate flags for admin announcements (mirrors Dart NotificationPreferencesState.isMethodEnabled).';

-- 3) Channel id for an alert-preference pair. Mirrors
--    AdminBroadcastChannels.idFor(soundEnabled:, vibrateEnabled:).
CREATE OR REPLACE FUNCTION public.admin_broadcast_channel_id(
  p_sound_enabled boolean,
  p_vibrate_enabled boolean
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN COALESCE(p_sound_enabled, true)
      AND COALESCE(p_vibrate_enabled, true) THEN 'admin_broadcasts'
    WHEN COALESCE(p_sound_enabled, true) THEN 'admin_broadcasts_sound'
    WHEN COALESCE(p_vibrate_enabled, true) THEN 'admin_broadcasts_vibrate'
    ELSE 'admin_broadcasts_silent'
  END;
$$;

REVOKE ALL ON FUNCTION public.admin_broadcast_channel_id(boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_broadcast_channel_id(boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_broadcast_channel_id(boolean, boolean) TO service_role;

COMMENT ON FUNCTION public.admin_broadcast_channel_id(boolean, boolean)
  IS 'Android channel id carrying the given admin-broadcast alert preference (mirrors lib/utils/notification_channels.dart).';


-- 4) queue_fcm_notification funnel: stamp every admin-broadcast row with the
--    recipient's alert preference + matching channel id. Kept here (instead of
--    inside send_admin_broadcast / queue_birthday_broadcast_notifications) so
--    all current and future admin producers inherit it, and so the fan-out
--    functions stay untouched. Explicit keys already present in p_data win.
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
  ) RETURNING id INTO notification_id;
  RETURN notification_id;
END;
$$;

COMMENT ON FUNCTION public.queue_fcm_notification(UUID, TEXT, TEXT, TEXT, JSONB, TEXT)
  IS 'Inserts a queue row; admin_broadcast rows gain sound/vibrate/channel_id from the recipient preferences.';

COMMIT;
