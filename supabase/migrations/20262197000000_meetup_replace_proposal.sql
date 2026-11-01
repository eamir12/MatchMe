-- Meet-up: the person who proposed meeting points can change them while the
-- other side is still deciding.
--
-- Nothing is agreed yet in the proposed state, so replacing your own offer
-- needs no consent round: the round and proposed_by stay the same and only
-- that round's landmark rows are swapped. The other participant sees the new
-- list through the existing meetup_landmarks realtime subscription, and the
-- counter limit is not consumed because this is not a counter-proposal.
--
-- Only the current proposer may replace. A session row lock serializes this
-- against a concurrent accept: one of the two wins and the other gets a
-- normal state error, never a half-updated proposal.

BEGIN;

CREATE OR REPLACE FUNCTION public.meetup_replace_proposal(
  p_session_id UUID,
  p_landmarks JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
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
  IF v_session.origin <> 'proximity' THEN
    -- Event meet-ups propose a venue zone, not landmarks; changing a pending
    -- zone is out of scope.
    RAISE EXCEPTION 'meetup_place_change_unavailable';
  END IF;
  IF v_session.proposed_by IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'meetup_not_proposer';
  END IF;

  -- Same round, same proposer: this is an edit of the pending offer, not a
  -- counter. Invalid input raises inside meetup_insert_landmarks and rolls
  -- the delete back, so the previous options survive a failed edit.
  DELETE FROM public.meetup_landmarks
  WHERE session_id = v_session.id
    AND round = v_session.proposal_round;

  PERFORM public.meetup_insert_landmarks(
    v_session.id,
    v_session.match_id,
    v_uid,
    v_session.proposal_round,
    p_landmarks
  );

  RETURN to_jsonb(v_session);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_replace_proposal(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_replace_proposal(UUID, JSONB) TO authenticated;

-- ---------------------------------------------------------------------------
-- Copy (en/es/he)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
('en','meetupChangeProposal','Change meeting points'),
('en','meetupChangeProposalSend','Update meeting points'),
('en','meetupProposalUpdated','Meeting points updated'),
('en','meetupRefreshPlaces','Find places near me'),
('en','meetupProposalChanged','The proposed places were updated. Choose again.'),
('es','meetupChangeProposal','Cambiar puntos de encuentro'),
('es','meetupChangeProposalSend','Actualizar puntos de encuentro'),
('es','meetupProposalUpdated','Puntos de encuentro actualizados'),
('es','meetupRefreshPlaces','Buscar lugares cerca de mí'),
('es','meetupProposalChanged','Los lugares propuestos se actualizaron. Elige de nuevo.'),
('he','meetupChangeProposal','שינוי נקודות המפגש'),
('he','meetupChangeProposalSend','עדכון נקודות המפגש'),
('he','meetupProposalUpdated','נקודות המפגש עודכנו'),
('he','meetupRefreshPlaces','חיפוש מקומות בקרבתי'),
('he','meetupProposalChanged','המקומות המוצעים עודכנו. בחרו שוב.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

NOTIFY pgrst, 'reload schema';

COMMIT;
