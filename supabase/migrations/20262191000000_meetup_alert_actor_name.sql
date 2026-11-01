-- Meet-up alerts named the wrong person: notify_meetup_signal,
-- notify_meetup_spot and notify_meetup_session read {name} from the partner
-- row (the receiver), so every wave, beacon, Spot-me card, proposal and
-- place-change request arrived as "<receiver> waved at you" — the recipient
-- saw their own name as the actor.
--
-- The locale still comes from the partner (the alert is localized for the
-- receiver); the name now comes from the actor and uses
-- public.mask_full_name, the app-wide "John S." format. Payloads are
-- unchanged (sender_id already identifies the actor).
--
-- The one-off repair at the end re-renders meet-up inbox rows already written
-- with the recipient's name, from the current translations and
-- data->>'sender_id'.

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_meetup_signal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Re-sending a beacon inserts a fresh row and stays live for 120 s. Alert
  -- at most once per two minutes instead of buzzing on every re-send.
  IF NEW.type = 'beacon' AND EXISTS (
    SELECT 1
    FROM public.user_notifications un
    JOIN public.matches m ON m.id = NEW.match_id
    WHERE un.user_id = CASE
        WHEN m.user1_id = NEW.sender_id THEN m.user2_id
        ELSE m.user1_id
      END
      AND un.type = 'meetup_beacon'
      AND un.data->>'match_id' = NEW.match_id::text
      AND un.data->>'sender_id' = NEW.sender_id::text
      AND un.created_at > now() - interval '2 minutes'
  ) THEN
    RETURN NEW;
  END IF;

  -- Locale belongs to the receiver; the name belongs to the actor.
  SELECT lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_locale
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

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
$$;

CREATE OR REPLACE FUNCTION public.notify_meetup_spot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_display TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_data JSONB;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Locale belongs to the receiver; the name belongs to the actor.
  SELECT lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_locale
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = NEW.sender_id THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

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

  v_title := replace(
    public._match_extended_text(v_locale, 'meetupSpotPushTitle', '📸 {name}'),
    '{name}', v_display);
  v_body := replace(
    public._match_extended_text(v_locale, 'meetupSpotPushBody',
      '{name} sent a Spot me card'),
    '{name}', v_display);

  -- No photo path, outfit, note or location in the payload.
  v_data := jsonb_build_object(
    'type', 'meetup_spot',
    'kind', 'meetup_spot',
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'senderId', NEW.sender_id::text,
    'sender_id', NEW.sender_id::text,
    'meetup_spot_id', NEW.id::text,
    'spot_kind', NEW.kind
  );

  PERFORM public._meetup_notify_partner(
    NEW.sender_id, NEW.match_id, 'meetup_spot', v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'notify_meetup_spot failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_meetup_session()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_display TEXT;
  v_someone TEXT;
  v_title TEXT;
  v_body TEXT;
  v_kind TEXT;
  v_actor UUID;
  v_data JSONB;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'proposed' THEN
      RETURN NEW;
    END IF;
    v_kind := 'meetup_proposal';
    v_actor := NEW.proposed_by;
  ELSE
    -- A counter-proposal flips proposed_by on the same open session; a
    -- place-change request sets a fresh pending landmark. Withdrawals
    -- (pending landmark back to NULL) stay silent.
    IF NEW.status = 'proposed'
       AND OLD.proposed_by IS DISTINCT FROM NEW.proposed_by THEN
      v_kind := 'meetup_proposal';
      v_actor := NEW.proposed_by;
    ELSIF NEW.pending_landmark_id IS NOT NULL
      AND OLD.pending_landmark_id IS DISTINCT FROM NEW.pending_landmark_id
      AND NEW.pending_change_by IS NOT NULL THEN
      v_kind := 'meetup_place_change';
      v_actor := NEW.pending_change_by;
    ELSE
      RETURN NEW;
    END IF;
  END IF;

  IF v_actor IS NULL OR NEW.match_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Locale belongs to the receiver; the name belongs to the actor.
  SELECT lower(btrim(COALESCE(u.preferred_language, 'en')))
    INTO v_locale
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = v_actor THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

  SELECT u.name INTO v_name
  FROM public.users u
  WHERE u.id = v_actor;

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

  IF v_kind = 'meetup_proposal' THEN
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupProposalPushTitle', '📍 {name}'),
      '{name}', v_display);
    v_body := replace(
      public._match_extended_text(
        v_locale,
        'meetupProposalPushBody',
        '{name} proposed a meeting point. Tap to see it'
      ),
      '{name}', v_display);
  ELSE
    v_title := replace(
      public._match_extended_text(
        v_locale,
        'meetupPlaceChangePushTitle',
        '📍 {name}'
      ),
      '{name}', v_display);
    v_body := replace(
      public._match_extended_text(
        v_locale,
        'meetupPlaceChangePushBody',
        '{name} suggested a new meeting point. Tap to review'
      ),
      '{name}', v_display);
  END IF;

  -- No coordinates, landmark ids or venue zones in the payload: the alert
  -- names the actor and the match only, like the other tool payloads.
  v_data := jsonb_build_object(
    'type', v_kind,
    'kind', v_kind,
    'matchId', NEW.match_id::text,
    'match_id', NEW.match_id::text,
    'senderId', v_actor::text,
    'sender_id', v_actor::text,
    'meetup_session_id', NEW.id::text
  );

  PERFORM public._meetup_notify_partner(
    v_actor, NEW.match_id, v_kind, v_title, v_body, v_data
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A failed alert must never block the proposal or the change request.
  RAISE WARNING 'notify_meetup_session failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- One-off repair: re-render meet-up inbox rows written with the recipient's
-- name. Only inbound rows (sender <> recipient) with a resolvable sender.
-- ---------------------------------------------------------------------------
WITH meetup_rows AS (
  SELECT un.id,
         un.type,
         un.data,
         lower(btrim(COALESCE(ru.preferred_language, 'en'))) AS raw_locale,
         s.name AS sender_name
  FROM public.user_notifications un
  JOIN public.users ru ON ru.id = un.user_id
  JOIN public.users s ON s.id::text = un.data->>'sender_id'
  WHERE un.type IN ('meetup_signal', 'meetup_beacon', 'meetup_spot',
                    'meetup_proposal', 'meetup_place_change')
    AND COALESCE(un.data->>'sender_id', '') <> ''
    AND un.data->>'sender_id' <> un.user_id::text
),
prepared AS (
  SELECT r.id,
         r.type,
         r.data,
         CASE
           WHEN r.raw_locale LIKE 'he%' THEN 'he'
           WHEN r.raw_locale LIKE 'es%' THEN 'es'
           ELSE 'en'
         END AS locale,
         COALESCE(
           NULLIF(public.mask_full_name(r.sender_name), 'Unknown User'),
           CASE
             WHEN r.raw_locale LIKE 'he%' THEN 'מישהו'
             WHEN r.raw_locale LIKE 'es%' THEN 'Alguien'
             ELSE 'Someone'
           END
         ) AS display_name
  FROM meetup_rows r
),
copy AS (
  SELECT p.id,
         p.data,
         p.locale,
         p.display_name,
         CASE p.type
           WHEN 'meetup_signal' THEN 'meetupWavePushTitle'
           WHEN 'meetup_beacon' THEN 'meetupBeaconPushTitle'
           WHEN 'meetup_spot' THEN 'meetupSpotPushTitle'
           WHEN 'meetup_proposal' THEN 'meetupProposalPushTitle'
           ELSE 'meetupPlaceChangePushTitle'
         END AS title_key,
         CASE p.type
           WHEN 'meetup_signal' THEN
             CASE lower(btrim(COALESCE(p.data->>'gesture', '')))
               WHEN 'hands_up' THEN 'meetupHandsUpPushBody'
               WHEN 'jumping' THEN 'meetupJumpingPushBody'
               WHEN 'arms_wide' THEN 'meetupArmsWidePushBody'
               ELSE 'meetupWavePushBody'
             END
           WHEN 'meetup_beacon' THEN 'meetupBeaconPushBody'
           WHEN 'meetup_spot' THEN 'meetupSpotPushBody'
           WHEN 'meetup_proposal' THEN 'meetupProposalPushBody'
           ELSE 'meetupPlaceChangePushBody'
         END AS body_key
  FROM prepared p
),
replacement AS (
  SELECT c.id,
         c.locale,
         c.display_name,
         c.title_key,
         c.body_key,
         CASE c.title_key
           WHEN 'meetupWavePushTitle' THEN '👋 {name}'
           WHEN 'meetupBeaconPushTitle' THEN '📡 {name}'
           WHEN 'meetupSpotPushTitle' THEN '📸 {name}'
           ELSE '📍 {name}'
         END AS title_default,
         CASE c.body_key
           WHEN 'meetupWavePushBody' THEN '{name} waved at you. Tap to wave back'
           WHEN 'meetupHandsUpPushBody' THEN '{name} raised both hands to find you'
           WHEN 'meetupJumpingPushBody' THEN '{name} is jumping to catch your eye'
           WHEN 'meetupArmsWidePushBody' THEN '{name} has both arms up to find you'
           WHEN 'meetupBeaconPushBody' THEN '{name} is showing a beacon. Look for the shape on their screen'
           WHEN 'meetupSpotPushBody' THEN '{name} sent a Spot me card'
           WHEN 'meetupProposalPushBody' THEN '{name} proposed a meeting point. Tap to see it'
           ELSE '{name} suggested a new meeting point. Tap to review'
         END AS body_default
  FROM copy c
)
UPDATE public.user_notifications un
SET title = replace(
      public._match_extended_text(r.locale, r.title_key, r.title_default),
      '{name}', r.display_name),
    body = replace(
      public._match_extended_text(r.locale, r.body_key, r.body_default),
      '{name}', r.display_name)
FROM replacement r
WHERE un.id = r.id;

COMMIT;
