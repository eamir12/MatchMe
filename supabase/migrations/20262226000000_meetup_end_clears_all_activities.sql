-- Ending a meet-up also resets match-scoped tools and live-location sharing.
-- These activities otherwise outlive the session and keep the match activity
-- indicator visible after either end action.

BEGIN;

CREATE OR REPLACE FUNCTION public.meetup_end(
  p_session_id UUID,
  p_reason TEXT DEFAULT 'found'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_session public.meetup_sessions%ROWTYPE;
  v_reason TEXT;
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

  IF v_session.status = 'ended' THEN
    RETURN to_jsonb(v_session);
  END IF;

  v_reason := CASE
    WHEN p_reason IN ('found', 'cancelled') THEN p_reason
    ELSE 'cancelled'
  END;

  UPDATE public.meetup_sessions
  SET status = 'ended',
      ended_at = now(),
      ended_by = v_uid,
      end_reason = v_reason,
      pending_landmark_id = NULL,
      pending_change_by = NULL,
      pending_change_at = NULL
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  DELETE FROM public.meetup_signals
  WHERE match_id = v_session.match_id;
  UPDATE public.meetup_spot_cards
  SET deleted_at = now()
  WHERE match_id = v_session.match_id
    AND deleted_at IS NULL;
  DELETE FROM public.location_share_signals
  WHERE match_id = v_session.match_id::TEXT;

  -- Keep the accepted place for the ended-session summary; drop suggestions
  -- that were never accepted.
  DELETE FROM public.meetup_landmarks
  WHERE session_id = v_session.id
    AND round = 3
    AND id IS DISTINCT FROM v_session.chosen_landmark_id;

  RETURN to_jsonb(v_session);
END;
$$;

REVOKE ALL ON FUNCTION public.meetup_end(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.meetup_end(UUID, TEXT) TO authenticated;

COMMIT;
