-- Migration: re-assert the inbox-capture version of enqueue_new_match_fcm.
--
-- Conflict: 20262084000000_enqueue_new_match_fcm.sql carries an invalid month
-- ("20") and therefore sorts AFTER 20261001010000_inbox_capture_beyond_push_prefs.sql,
-- which was written to supersede it. On any database that applied migrations in
-- filename order, the older v1 trigger function (CONTINUE past recipients whose
-- prefs disable new_match pushes; no direct user_notifications fallback) ran
-- last and replaced the v2. Renaming the typo'd file is not safe for databases
-- that already recorded it as applied (the CLI would re-run the renamed file
-- last, clobbering v2 again), so this migration re-asserts v2 with its current
-- timestamp. CREATE OR REPLACE FUNCTION is idempotent; on databases where v2
-- is already active this is a no-op.
--
-- v2 behavior (identical to 20261001010000): inbox row for every recipient
-- regardless of push preferences or registered devices; FCM queue rows only
-- for enabled recipients with tokens; direct user_notifications insert for
-- disabled/token-less recipients.

BEGIN;

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

COMMIT;
