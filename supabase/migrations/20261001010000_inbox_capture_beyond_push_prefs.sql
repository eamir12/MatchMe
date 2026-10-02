-- Migration: Notification inbox records EVERYTHING, regardless of push prefs.
--
-- Follows 20261001000000_create_user_notification_inbox.sql, which captured
-- notifications at the moment they were actually sent. Per product decision,
-- the inbox is a complete record: a user who disabled a notification type
-- (or has no registered device) still gets the inbox row — only the FCM push
-- itself is suppressed. The TS writers (push-message, cron-jobs) were updated
-- in kind; this migration fixes the two SQL writers whose pref gate sat
-- before any enqueue:
--
--   1) enqueue_new_match_fcm (matches INSERT trigger): previously CONTINUED
--      past recipients whose prefs disabled new_match pushes, so those users
--      got no record. Now the localized copy is built first; a disabled or
--      token-less recipient gets a direct user_notifications insert, while an
--      enabled one keeps going through notification_queue (whose capture
--      trigger writes the inbox row) — exactly one row either way.
--
--   2) notify_match_extended: same restructure for match-extension notices.
--
-- Also extends the inbox dedupe trigger to collapse duplicate new-match rows:
-- a match can reach both the SQL queue path (type 'match') and the
-- push-message direct path (type 'new_match') for the same match_id.

BEGIN;

-- 1) enqueue_new_match_fcm: inbox row for every recipient, FCM only when enabled.
CREATE OR REPLACE FUNCTION public.enqueue_new_match_fcm()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_recipient_id uuid;
  v_other_id uuid;
  v_prefs jsonb;
  v_locale text;
  v_other_raw_name text;
  v_other_first text;
  v_someone text;
  v_title text;
  v_body text;
  v_data jsonb;
  v_token text;
  v_platform text;
  v_any_token boolean;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RETURN NEW;
  END IF;

  IF NEW.user1_id IS NULL OR NEW.user2_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Ignore historical backfills/repairs: only freshly created matches buzz.
  -- Normal inserts carry created_at ~= now(); a NULL created_at is treated
  -- as fresh (never skip a real match on a missing timestamp).
  IF NEW.created_at IS NOT NULL
     AND NEW.created_at < (now() - INTERVAL '1 hour') THEN
    RETURN NEW;
  END IF;

  -- One record per participant (both sides get their own localized copy).
  FOR v_recipient_id, v_other_id IN
    SELECT NEW.user1_id, NEW.user2_id
    UNION ALL
    SELECT NEW.user2_id, NEW.user1_id
  LOOP
    BEGIN
      SELECT u.notification_preferences,
             lower(btrim(COALESCE(u.preferred_language, 'en')))
      INTO v_prefs, v_locale
      FROM public.users u
      WHERE u.id = v_recipient_id;

      -- 'en' plus any unknown/missing locale falls back to English.
      v_locale := COALESCE(v_locale, 'en');
      IF v_locale LIKE 'he%' THEN
        v_locale := 'he';
      ELSIF v_locale LIKE 'es%' THEN
        v_locale := 'es';
      ELSE
        v_locale := 'en';
      END IF;

      SELECT btrim(COALESCE(u.name, ''))
      INTO v_other_raw_name
      FROM public.users u
      WHERE u.id = v_other_id;

      -- First name token, max 20 chars (mirrors firstTokenName).
      v_other_first := split_part(COALESCE(NULLIF(v_other_raw_name, ''), ''), ' ', 1);
      IF v_other_first IS NULL OR btrim(v_other_first) = '' THEN
        v_other_first := NULL;
      ELSE
        v_other_first := left(btrim(v_other_first), 20);
      END IF;

      -- Localized copy (mirrors push-message _pushStrings for new_match).
      IF v_locale = 'he' THEN
        v_someone := 'מישהו';
        v_title := 'התאמה חדשה!';
        v_body := 'יש לך התאמה עם ' || COALESCE(v_other_first, v_someone);
      ELSIF v_locale = 'es' THEN
        v_someone := 'Alguien';
        v_title := '¡Nueva coincidencia!';
        v_body := 'Coincidiste con ' || COALESCE(v_other_first, v_someone);
      ELSE
        v_someone := 'Someone';
        v_title := 'New Match!';
        v_body := 'You matched with ' || COALESCE(v_other_first, v_someone);
      END IF;

      v_data := jsonb_build_object(
        'type', 'match',
        'kind', 'match',
        'matchId', NEW.id::text,
        'match_id', NEW.id::text,
        'tabIndex', '1',
        'otherUserId', v_other_id::text,
        'badge', '1'
      );

      -- Inbox records every new match, regardless of push preferences or
      -- registered devices.
      IF NOT public.is_match_push_enabled(v_prefs) THEN
        INSERT INTO public.user_notifications (user_id, type, title, body, data)
        VALUES (v_recipient_id, 'match', v_title, v_body, v_data);
        CONTINUE;
      END IF;

      v_any_token := false;
      FOR v_token, v_platform IN
        SELECT DISTINCT ON (NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''))
          NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') AS fcm_token,
          us.platform
        FROM public.user_session us
        WHERE us.user_id = v_recipient_id
          AND us.revoked = false
          AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
        ORDER BY NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), us.last_active_at DESC NULLS LAST
      LOOP
        v_any_token := true;
        INSERT INTO public.notification_queue (
          user_id,
          fcm_token,
          title,
          body,
          data,
          platform
        )
        VALUES (
          v_recipient_id,
          v_token,
          v_title,
          v_body,
          v_data,
          COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
        );
      END LOOP;

      -- No registered device: no queue row (hence no capture-trigger row),
      -- so write the inbox record directly.
      IF NOT v_any_token THEN
        INSERT INTO public.user_notifications (user_id, type, title, body, data)
        VALUES (v_recipient_id, 'match', v_title, v_body, v_data);
      END IF;
    EXCEPTION WHEN others THEN
      -- Per-recipient failures must not block the other side (or the match).
      CONTINUE;
    END;
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN others THEN
  -- Match creation must never fail because of notification enqueueing.
  RETURN NEW;
END;
$$;

-- 2) notify_match_extended: inbox row for the peer, FCM only when enabled.
CREATE OR REPLACE FUNCTION public.notify_match_extended(
  p_actor_id uuid,
  p_match_id uuid,
  p_expires_at timestamptz,
  p_extension_seconds int
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_peer_id uuid;
  v_prefs jsonb;
  v_locale text;
  v_name text;
  v_title text;
  v_body text;
  v_data jsonb;
  v_enqueued int := 0;
  v_token text;
  v_platform text;
  v_enabled text;
  v_any_token boolean;
BEGIN
  IF p_actor_id IS NULL OR p_match_id IS NULL THEN RETURN 0; END IF;

  SELECT NULLIF(config_value::text,'')::text INTO v_enabled
  FROM public.app_config WHERE config_key = 'match_extended.notify_peer' LIMIT 1;
  IF lower(COALESCE(v_enabled, 'true')) <> 'true' THEN RETURN 0; END IF;

  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  IF p_actor_id = v_match.user1_id THEN
    v_peer_id := v_match.user2_id;
  ELSIF p_actor_id = v_match.user2_id THEN
    v_peer_id := v_match.user1_id;
  ELSE
    RETURN 0;
  END IF;
  IF v_peer_id IS NULL THEN RETURN 0; END IF;

  SELECT u.notification_preferences, u.preferred_language
    INTO v_prefs, v_locale
  FROM public.users u
  WHERE u.id = v_peer_id;

  v_locale := lower(btrim(COALESCE(v_locale, 'en')));
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  -- Masked name, consistent with get_user_recent_matches.
  BEGIN
    v_name := public.mask_full_name((SELECT u.name FROM public.users u WHERE u.id = p_actor_id));
  EXCEPTION WHEN OTHERS THEN
    v_name := NULL;
  END;
  IF v_name IS NULL OR btrim(v_name) = '' THEN
    v_name := CASE
      WHEN v_locale LIKE 'he%' THEN 'מישהו'
      WHEN v_locale LIKE 'es%' THEN 'Alguien'
      ELSE 'Someone'
    END;
  END IF;

  v_title := replace(
    public._match_extended_text(
      v_locale, 'matchExtendedPushTitle', '{name} gave you more time'
    ), '{name}', v_name);
  v_body := public._match_extended_text(
    v_locale, 'matchExtendedPushBody', 'Say hi before this match runs out.'
  );

  v_data := jsonb_build_object(
    'type', 'match_extended',
    'kind', 'match_extended',
    'matchId', p_match_id::text,
    'match_id', p_match_id::text,
    'otherUserId', p_actor_id::text,
    'other_user_id', p_actor_id::text,
    'extension_seconds', COALESCE(p_extension_seconds, 0),
    'expires_at', to_char(COALESCE(p_expires_at, now()), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  -- Inbox records every extension notice, regardless of push preferences or
  -- registered devices.
  IF NOT public._match_extended_push_enabled(
       v_prefs, 'match_extended', 'enable_match_extended_notifications'
     ) THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_peer_id, 'match_extended', v_title, v_body, v_data);
    RETURN 1;
  END IF;

  FOR v_token, v_platform IN
    SELECT DISTINCT ON (NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''))
      NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') AS fcm_token,
      us.platform
    FROM public.user_session us
    WHERE us.user_id = v_peer_id
      AND us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
    ORDER BY NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), us.last_active_at DESC NULLS LAST
  LOOP
    INSERT INTO public.notification_queue (
      user_id, fcm_token, title, body, data, platform
    )
    VALUES (
      v_peer_id,
      v_token,
      v_title,
      v_body,
      v_data,
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
    v_enqueued := v_enqueued + 1;
  END LOOP;

  -- No registered device: no queue row (hence no capture-trigger row), so
  -- write the inbox record directly.
  IF v_enqueued = 0 THEN
    INSERT INTO public.user_notifications (user_id, type, title, body, data)
    VALUES (v_peer_id, 'match_extended', v_title, v_body, v_data);
    RETURN 1;
  END IF;

  RETURN v_enqueued;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_match_extended(uuid, uuid, timestamptz, int) TO service_role;

-- 3) Extend the inbox dedupe trigger: a new match can reach both the SQL
--    queue path (type 'match') and the push-message direct path
--    (type 'new_match') for the same match_id — keep the first row only.
--    Chat rows keep their per-message_id dedupe.
CREATE OR REPLACE FUNCTION public.trg_user_notifications_dedupe()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id text;
  v_match_id text;
BEGIN
  v_message_id := COALESCE(NEW.data->>'message_id', '');
  v_match_id := COALESCE(NEW.data->>'match_id', COALESCE(NEW.data->>'matchId', ''));

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

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_notifications_dedupe ON public.user_notifications;
CREATE TRIGGER trg_user_notifications_dedupe
  BEFORE INSERT ON public.user_notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_user_notifications_dedupe();

-- Backstop for concurrent writers on the same new match (the trigger above
-- handles the sequential case).
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_match_dedupe
  ON public.user_notifications (
    user_id,
    (COALESCE(data->>'match_id', data->>'matchId'))
  )
  WHERE type IN ('match', 'new_match')
    AND COALESCE(data->>'match_id', data->>'matchId') <> '';

COMMIT;
