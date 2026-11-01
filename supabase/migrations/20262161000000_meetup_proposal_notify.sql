-- Meeting-point proposals and place-change requests had no receiver alert
-- outside an open chat: unlike waves, beacons and Spot cards, session rows
-- never wrote an inbox/push row, so the app-wide banner, the chat-list
-- indicator and the desktop toasts could not surface them. This adds the
-- missing trigger so a proposal, a counter-proposal and a fresh place-change
-- request alert the partner exactly like the other meet-up tools.

CREATE OR REPLACE FUNCTION public.notify_meetup_session()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_locale TEXT;
  v_name TEXT;
  v_first TEXT;
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

  SELECT lower(btrim(COALESCE(u.preferred_language, 'en'))), u.name
    INTO v_locale, v_name
  FROM public.users u
  WHERE u.id IN (
    SELECT CASE
      WHEN m.user1_id = v_actor THEN m.user2_id
      ELSE m.user1_id
    END
    FROM public.matches m
    WHERE m.id = NEW.match_id
  );

  v_locale := COALESCE(v_locale, 'en');
  IF v_locale LIKE 'he%' THEN v_locale := 'he';
  ELSIF v_locale LIKE 'es%' THEN v_locale := 'es';
  ELSE v_locale := 'en';
  END IF;

  v_first := left(split_part(btrim(COALESCE(v_name, '')), ' ', 1), 20);
  v_someone := CASE
    WHEN v_locale = 'he' THEN 'מישהו'
    WHEN v_locale = 'es' THEN 'Alguien'
    ELSE 'Someone'
  END;
  v_first := COALESCE(NULLIF(v_first, ''), v_someone);

  IF v_kind = 'meetup_proposal' THEN
    v_title := replace(
      public._match_extended_text(v_locale, 'meetupProposalPushTitle', '📍 {name}'),
      '{name}', v_first);
    v_body := replace(
      public._match_extended_text(
        v_locale,
        'meetupProposalPushBody',
        '{name} proposed a meeting point. Tap to see it'
      ),
      '{name}', v_first);
  ELSE
    v_title := replace(
      public._match_extended_text(
        v_locale,
        'meetupPlaceChangePushTitle',
        '📍 {name}'
      ),
      '{name}', v_first);
    v_body := replace(
      public._match_extended_text(
        v_locale,
        'meetupPlaceChangePushBody',
        '{name} suggested a new meeting point. Tap to review'
      ),
      '{name}', v_first);
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

DROP TRIGGER IF EXISTS trg_notify_meetup_session_insert ON public.meetup_sessions;
CREATE TRIGGER trg_notify_meetup_session_insert
  AFTER INSERT ON public.meetup_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_meetup_session();

DROP TRIGGER IF EXISTS trg_notify_meetup_session_update ON public.meetup_sessions;
CREATE TRIGGER trg_notify_meetup_session_update
  AFTER UPDATE ON public.meetup_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_meetup_session();

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'meetupProposalPushTitle', '📍 {name}'),
  ('en', 'meetupProposalPushBody',
   '{name} proposed a meeting point. Tap to see it'),
  ('en', 'meetupPlaceChangePushTitle', '📍 {name}'),
  ('en', 'meetupPlaceChangePushBody',
   '{name} suggested a new meeting point. Tap to review'),
  ('es', 'meetupProposalPushTitle', '📍 {name}'),
  ('es', 'meetupProposalPushBody',
   '{name} propuso un punto de encuentro. Toca para verlo'),
  ('es', 'meetupPlaceChangePushTitle', '📍 {name}'),
  ('es', 'meetupPlaceChangePushBody',
   '{name} sugirió un nuevo punto de encuentro. Toca para revisarlo'),
  ('he', 'meetupProposalPushTitle', '📍 {name}'),
  ('he', 'meetupProposalPushBody',
   '{name} הציעו נקודת מפגש. הקישו לצפייה'),
  ('he', 'meetupPlaceChangePushTitle', '📍 {name}'),
  ('he', 'meetupPlaceChangePushBody',
   '{name} הציעו נקודת מפגש חדשה. הקישו לבדיקה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
