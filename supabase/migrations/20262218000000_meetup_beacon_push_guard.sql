-- The beacon push throttle from 20262160000000 never fired for a partner who
-- was actually reachable by push.
--
-- notify_meetup_signal() suppresses a second beacon alert inside 2 minutes by
-- looking for an earlier meetup_beacon record for the same match and sender.
-- It looked in public.user_notifications only. But _meetup_notify_partner()
-- writes a user_notifications row *only* when the partner has meet-up pushes
-- turned off or has no registered device; a partner with push enabled and a
-- token gets a notification_queue row instead and no inbox row at all. The
-- EXISTS therefore never found anything for push-capable partners, so every
-- accepted re-send (the RPC allows one every 20 s) enqueued another buzz.
--
-- The check now looks for the same event in either table: notification_queue
-- for pushed partners, user_notifications for inbox-only partners. Same match,
-- same sender, same 2-minute window, so it stays direction-scoped: the other
-- person's beacon is never mistaken for a repeat of yours.
--
-- Waves are unaffected: only NEW.type = 'beacon' enters this branch.
--
-- Body is the live 20262160000000 definition with a pre-resolved v_partner_id,
-- which also feeds the locale lookup (same CASE expression as before), and the
-- two-table guard. Idempotent CREATE OR REPLACE; signature and ACL unchanged.

CREATE OR REPLACE FUNCTION public.notify_meetup_signal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_display TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_kind TEXT;
  v_gesture TEXT;
  v_data JSONB;
  v_partner_id UUID;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      WHEN m.user2_id = NEW.sender_id THEN m.user1_id
    END
    INTO v_partner_id
  FROM public.matches m
  WHERE m.id = NEW.match_id;

  -- Re-sending a beacon inserts a fresh row and stays live for 120 s. Alert
  -- at most once per two minutes instead of buzzing on every re-send. A
  -- pushed partner is recorded in notification_queue (one row per device), an
  -- inbox-only partner in user_notifications, so both count as "already
  -- alerted".
  IF NEW.type = 'beacon' AND v_partner_id IS NOT NULL AND (
    EXISTS (
      SELECT 1
      FROM public.user_notifications un
      WHERE un.user_id = v_partner_id
        AND un.type = 'meetup_beacon'
        AND un.data->>'match_id' = NEW.match_id::text
        AND un.data->>'sender_id' = NEW.sender_id::text
        AND un.created_at > now() - interval '2 minutes'
    )
    OR EXISTS (
      SELECT 1
      FROM public.notification_queue q
      WHERE q.user_id = v_partner_id
        AND q.data->>'type' = 'meetup_beacon'
        AND q.data->>'match_id' = NEW.match_id::text
        AND q.data->>'sender_id' = NEW.sender_id::text
        AND q.created_at > now() - interval '2 minutes'
    )
  ) THEN
    RETURN NEW;
  END IF;

  -- Locale belongs to the receiver; the name belongs to the actor.
  SELECT lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_locale
  FROM public.users u
  WHERE u.id = v_partner_id;

  SELECT u.name INTO v_name
  FROM public.users u
  WHERE u.id = NEW.sender_id;

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;
  -- mask_full_name returns NULL for a name that cannot be shown as
  -- "First L." (single-word); 'Unknown User' covers the older definition.
  v_display := COALESCE(
    NULLIF(public.mask_full_name(v_name), 'Unknown User'),
    v_someone
  );

  IF NEW.type = 'beacon' THEN
    v_kind := 'meetup_beacon';
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupBeaconPushTitle', '📡 {name}'),
      '{name}', v_display);
    v_body := replace(
      public._match_extended_text(v_locale, 'meetupBeaconPushBody',
        '{name} is broadcasting a beacon so you can find each other'),
      '{name}', v_display);
  ELSE
    v_kind := 'meetup_signal';
    v_gesture := lower(btrim(COALESCE(NEW.payload->>'gesture', '')));
    IF v_gesture NOT IN ('wave', 'hands_up', 'jumping', 'arms_wide') THEN
      v_gesture := 'wave';
    END IF;
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupWavePushTitle', '👋 {name}'),
      '{name}', v_display);
    v_body := replace(
      public._match_extended_text(
        v_locale,
        CASE v_gesture
          WHEN 'hands_up' THEN 'meetupHandsUpPushBody'
          WHEN 'jumping' THEN 'meetupJumpingPushBody'
          WHEN 'arms_wide' THEN 'meetupArmsWidePushBody'
          ELSE 'meetupWavePushBody'
        END,
        '{name} waved at you. Tap to wave back'
      ),
      '{name}', v_display);
  END IF;

  v_data := jsonb_build_object(
    'type', v_kind,
    'kind', v_kind,
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'senderId', NEW.sender_id::text,
    'sender_id', NEW.sender_id::text,
    'meetup_signal_id', NEW.id::text,
    'gesture', v_gesture
  );

  PERFORM public._meetup_notify_partner(
    NEW.sender_id, NEW.match_id, v_kind, v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A failed alert must never block the signal itself.
  RAISE WARNING 'notify_meetup_signal failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;
