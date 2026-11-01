-- Hotfix for databases where 20262156000000 was already applied.
--
-- meetup_propose / meetup_counter called meetup_insert_landmarks with a bare
-- integer round literal. Postgres does not use the integer -> smallint
-- assignment cast during function resolution, so the call failed with
-- "function public.meetup_insert_landmarks(uuid, uuid, uuid, integer, jsonb)
-- does not exist" and every "Send meeting points" attempt rolled back.

BEGIN;

CREATE OR REPLACE FUNCTION public.meetup_propose(
  p_match_id UUID,
  p_origin TEXT,
  p_venue_zone TEXT,
  p_landmarks JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_zone TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;
  IF NOT public.meetup_match_participant(p_match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  IF p_origin IS NULL OR p_origin NOT IN ('proximity', 'event') THEN
    RAISE EXCEPTION 'meetup_invalid_origin';
  END IF;

  v_zone := NULLIF(btrim(COALESCE(p_venue_zone, '')), '');
  IF p_origin = 'event' THEN
    IF v_zone IS NULL OR char_length(v_zone) > 120 THEN
      RAISE EXCEPTION 'meetup_invalid_zone';
    END IF;
  ELSE
    v_zone := NULL;
  END IF;

  -- The cleanup job runs every ten minutes. Close any stale open session
  -- first so the caller does not have to wait for it before starting again.
  UPDATE public.meetup_sessions
  SET status = 'ended',
      ended_at = now(),
      ended_by = v_uid,
      end_reason = 'expired'
  WHERE match_id = p_match_id
    AND status IN ('proposed', 'active')
    AND expires_at <= now();

  BEGIN
    INSERT INTO public.meetup_sessions (
      match_id, created_by, status, origin, proposed_by, proposal_round, venue_zone
    ) VALUES (
      p_match_id, v_uid, 'proposed', p_origin, v_uid, 1, v_zone
    )
    RETURNING * INTO v_session;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'meetup_already_active';
  END;

  IF p_origin = 'proximity' THEN
    PERFORM public.meetup_insert_landmarks(
      v_session.id, p_match_id, v_uid, 1::SMALLINT, p_landmarks
    );
  END IF;

  RETURN to_jsonb(v_session);
END;
$$;

CREATE OR REPLACE FUNCTION public.meetup_counter(
  p_session_id UUID,
  p_venue_zone TEXT,
  p_landmarks JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_zone TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'meetup_auth_required';
  END IF;

  SELECT * INTO v_session
  FROM public.meetup_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'meetup_not_found';
  END IF;
  IF NOT public.meetup_match_participant(v_session.match_id) THEN
    RAISE EXCEPTION 'meetup_not_participant';
  END IF;
  IF v_session.status <> 'proposed' OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'meetup_not_proposed';
  END IF;
  IF v_session.proposed_by = v_uid THEN
    RAISE EXCEPTION 'meetup_waiting_for_other';
  END IF;
  IF v_session.proposal_round >= 2 THEN
    RAISE EXCEPTION 'meetup_counter_limit';
  END IF;

  v_zone := NULLIF(btrim(COALESCE(p_venue_zone, '')), '');
  IF v_session.origin = 'event' THEN
    IF v_zone IS NULL OR char_length(v_zone) > 120 THEN
      RAISE EXCEPTION 'meetup_invalid_zone';
    END IF;
  ELSE
    v_zone := v_session.venue_zone;
  END IF;

  DELETE FROM public.meetup_landmarks
  WHERE session_id = v_session.id AND round = 2;

  IF v_session.origin = 'proximity' THEN
    PERFORM public.meetup_insert_landmarks(
      v_session.id, v_session.match_id, v_uid, 2::SMALLINT, p_landmarks
    );
  END IF;

  UPDATE public.meetup_sessions
  SET proposed_by = v_uid,
      proposal_round = 2,
      venue_zone = v_zone
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  RETURN to_jsonb(v_session);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_propose(UUID, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.meetup_counter(UUID, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_propose(UUID, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meetup_counter(UUID, TEXT, JSONB) TO authenticated;

COMMIT;
