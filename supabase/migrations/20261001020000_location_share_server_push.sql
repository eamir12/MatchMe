-- Migration: Server-side push for live-location-share alerts.
--
-- Until now a "user X is sharing their live location with you" alert was
-- raised ONLY by the recipient's client listening to realtime changes on
-- location_share_signals (lib/providers/location_share_provider.dart). If the
-- recipient's app was killed, swiped away, or the device had just rebooted,
-- the realtime socket did not exist and the alert was silently lost until the
-- next app open.
--
-- This migration adds an AFTER INSERT trigger on location_share_signals that
-- enqueues an FCM push (type 'location_share') for the recipient through
-- notification_queue — the same reliable path as new matches and expiry
-- warnings. The FCM message carries a visible notification payload, so the
-- OS shows it in the tray regardless of app state (foreground, background,
-- killed, after reboot; FCM TTL is 7 days).
--
-- Consistency with the notification-inbox design:
--   - Recipients with location_sharing pushes disabled in the Notifications
--     Settings screen get NO push, but still get their inbox row (direct
--     insert), because the inbox records everything.
--   - Enabled recipients get the push via notification_queue, whose capture
--     trigger (20261001000000) writes the inbox row.
--   - Recipients with no registered device get the inbox row directly.
--   So exactly one inbox row per share start, from the server. The client
--   no longer inserts its own row (its local insert was removed).
--
-- Dedupe: the sharer deletes the stale signal before inserting, so a normal
-- share start is exactly one INSERT. As a guard against double-inserts
-- (multi-device retry), a push is skipped when an identical inbox row
-- (same user, match_id, expires_at) already exists.
--
-- Prefs gate mirrors the client matrix: pause / global push /
-- matrix.location_sharing.push. There is no legacy boolean flag for
-- location_sharing, so a never-present key is used as the legacy fallback.

BEGIN;

-- 1) Localized copy (en / es / he). {name} is replaced with the sharer's
--    first name, consistent with the other push types.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'locationSharePushTitle', '📍 {name}'),
  ('en', 'locationSharePushBody',  '{name} is sharing their live location with you'),
  ('he', 'locationSharePushTitle', '📍 {name}'),
  ('he', 'locationSharePushBody',  '{name} משתף/ת איתכם את המיקום החי שלו/ה'),
  ('es', 'locationSharePushTitle', '📍 {name}'),
  ('es', 'locationSharePushBody',  '{name} está compartiendo su ubicación en vivo contigo')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- 2) Trigger: enqueue the recipient push when a share signal is created.
CREATE OR REPLACE FUNCTION public.notify_location_share_started()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_partner_id uuid;
  v_prefs jsonb;
  v_locale text;
  v_sharer_name text;
  v_first text;
  v_someone text;
  v_title text;
  v_body text;
  v_data jsonb;
  v_token text;
  v_platform text;
  v_any_token boolean;
BEGIN
  IF NEW.sharer_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = NEW.match_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF NEW.sharer_id = v_match.user1_id THEN
    v_partner_id := v_match.user2_id;
  ELSIF NEW.sharer_id = v_match.user2_id THEN
    v_partner_id := v_match.user1_id;
  ELSE
    RETURN NEW;
  END IF;
  IF v_partner_id IS NULL THEN RETURN NEW; END IF;

  -- Dedupe guard: identical share session (same match + expiry) already
  -- recorded for this recipient (e.g. multi-device retry) → skip.
  IF EXISTS (
    SELECT 1 FROM public.user_notifications un
    WHERE un.user_id = v_partner_id
      AND un.type = 'location_share'
      AND un.data->>'match_id' = NEW.match_id::text
      AND COALESCE(un.data->>'expires_at', '') =
          COALESCE(to_char(NEW.expires_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')
  ) THEN
    RETURN NEW;
  END IF;

  SELECT u.notification_preferences, lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_prefs, v_locale
  FROM public.users u
  WHERE u.id = v_partner_id;

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  -- Sharer's first name only (consistent with the other push types).
  BEGIN
    v_sharer_name := (SELECT u.name FROM public.users u WHERE u.id = NEW.sharer_id);
  EXCEPTION WHEN OTHERS THEN
    v_sharer_name := NULL;
  END;
  v_first := split_part(COALESCE(v_sharer_name, ''), ' ', 1);
  IF v_first <> '' THEN
    v_first := left(v_first, 20);
  END IF;

  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;

  v_title := replace(
    public._match_extended_text(v_locale, 'locationSharePushTitle', '📍 {name}'),
    '{name}', COALESCE(NULLIF(v_first, ''), v_someone));
  v_body := replace(
    public._match_extended_text(v_locale, 'locationSharePushBody', '{name} is sharing their live location with you'),
    '{name}', COALESCE(NULLIF(v_first, ''), v_someone));

  v_data := jsonb_build_object(
    'type', 'location_share',
    'kind', 'location_share',
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'sharerId', NEW.sharer_id::text,
    'sharer_id', NEW.sharer_id::text,
    'otherUserId', v_partner_id::text
  );
  IF NEW.expires_at IS NOT NULL THEN
    v_data := v_data || jsonb_build_object('expires_at', to_char(NEW.expires_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  END IF;

  -- Inbox records every share alert, regardless of push preferences or
  -- registered devices.
  IF NOT public._match_extended_push_enabled(
       v_prefs, 'location_sharing', 'enable_location_share_notifications'
     ) THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_partner_id, 'location_share', v_title, v_body, v_data);
    RETURN NEW;
  END IF;

  v_any_token := false;
  FOR v_token, v_platform IN
    SELECT DISTINCT ON (NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''))
      NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') AS fcm_token,
      us.platform
    FROM public.user_session us
    WHERE us.user_id = v_partner_id
      AND us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
    ORDER BY NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), us.last_active_at DESC NULLS LAST
  LOOP
    v_any_token := true;
    INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
    )
    VALUES (
      v_partner_id,
      v_token,
      v_title,
      v_body,
      v_data,
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
  END LOOP;

  -- No registered device: no queue row (hence no capture-trigger row), so
  -- write the inbox record directly.
  IF NOT v_any_token THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_partner_id, 'location_share', v_title, v_body, v_data);
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A failed alert must never block the share itself.
  RAISE WARNING 'notify_location_share_started failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_location_share_started ON public.location_share_signals;
CREATE TRIGGER trg_notify_location_share_started
  AFTER INSERT ON public.location_share_signals
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_location_share_started();

COMMIT;
