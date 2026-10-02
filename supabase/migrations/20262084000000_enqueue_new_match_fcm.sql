-- Migration: server-driven new-match push via notification_queue.
--
-- Until now nothing ever sent a "new match" push: matches are created by SQL
-- matching functions, and the only push-message caller is translate-proxy
-- (chat). Clients therefore learned about matches only through Realtime
-- (needs a live engine) or the native 2-minute polling window (misses
-- anything older). Killed apps on iOS and offline-then-reconnect devices
-- could miss the buzz entirely.
--
-- This adds an AFTER INSERT trigger on matches that enqueues one
-- notification_queue row per participant. The existing cron Task 4 drains
-- the queue over FCM (7-day TTL, per-token retries), and every client
-- (Android tray, iOS NSE, web SW, foreground handlers) already routes
-- data type/kind = 'match' to the new-match notification.
--
-- Gating: ONLY notification preferences gate (paused / global push off /
-- matrix new_match off / legacy flag off), mirroring
-- isPushEnabledForPrefs(prefs, 'new_match', 'enable_new_match_notifications')
-- in push-message. Visibility, pinned location, background-matching mode
-- and app foreground/background state NEVER gate: a new match must buzz
-- regardless. The trigger can never break match creation (exception guard).

BEGIN;

-- Mirror of isPushEnabledForPrefs() for the new_match matrix key.
-- Default allow; malformed values fail open except explicit false.
CREATE OR REPLACE FUNCTION public.is_match_push_enabled(p_prefs jsonb)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_text text;
  v_num bigint;
  v_now_ms bigint;
BEGIN
  IF p_prefs IS NULL OR jsonb_typeof(p_prefs) <> 'object' THEN
    RETURN true;
  END IF;

  IF lower(btrim(p_prefs->>'paused_indefinitely')) = 'true' THEN
    RETURN false;
  END IF;

  v_text := btrim(p_prefs->>'paused_until_ms_utc');
  IF v_text IS NOT NULL AND v_text <> '' AND v_text ~ '^[0-9]+$'
     AND char_length(v_text) <= 15 THEN
    v_num := v_text::bigint;
    v_now_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint;
    IF v_num > v_now_ms THEN
      RETURN false;
    END IF;
  END IF;

  IF lower(btrim(p_prefs->'global_methods'->>'push')) = 'false' THEN
    RETURN false;
  END IF;

  IF jsonb_typeof(p_prefs->'matrix'->'new_match'->'push') = 'boolean' THEN
    RETURN (p_prefs->'matrix'->'new_match'->>'push')::boolean;
  END IF;

  v_text := lower(btrim(p_prefs->>'enable_new_match_notifications'));
  IF v_text = 'true' THEN
    RETURN true;
  END IF;
  IF v_text = 'false' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

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
  v_token text;
  v_platform text;
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

  -- One queue row per participant (both sides get their own localized copy).
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

      IF NOT public.is_match_push_enabled(v_prefs) THEN
        CONTINUE;
      END IF;

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
          jsonb_build_object(
            'type', 'match',
            'kind', 'match',
            'matchId', NEW.id::text,
            'match_id', NEW.id::text,
            'tabIndex', '1',
            'otherUserId', v_other_id::text,
            'badge', '1'
          ),
          COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
        );
      END LOOP;
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

DROP TRIGGER IF EXISTS trg_enqueue_new_match_fcm ON public.matches;
CREATE TRIGGER trg_enqueue_new_match_fcm
AFTER INSERT ON public.matches
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_new_match_fcm();

COMMIT;
