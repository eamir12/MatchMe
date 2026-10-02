-- Migration: Fix submit_match_rating to also delete from pending_rating_prompts
-- When a user submits a rating, the pending_rating_prompts row must also be
-- removed so the RatingPromptWatcher doesn't re-prompt on next app start.

BEGIN;

CREATE OR REPLACE FUNCTION public.submit_match_rating(
  p_match_id uuid,
  p_q1 integer,
  p_q2 integer,
  p_q3 integer,
  p_q4 integer,
  p_q5 integer
)
RETURNS void AS $$
DECLARE
  v_other uuid;
BEGIN
  SELECT CASE WHEN m.user1_id = auth.uid() THEN m.user2_id ELSE m.user1_id END
    INTO v_other
  FROM public.matches m
  WHERE m.id = p_match_id AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid());

  IF v_other IS NULL THEN
    RAISE EXCEPTION 'not_a_match_participant';
  END IF;

  INSERT INTO public.match_ratings (match_id, rater_id, ratee_id, q1, q2, q3, q4, q5)
  VALUES (p_match_id, auth.uid(), v_other, p_q1, p_q2, p_q3, p_q4, p_q5);

  INSERT INTO public.match_rating_prompts (match_id, user_id, met_answer, met_confirmed, met_answered_at, rating_submitted_at, next_prompt_at)
  VALUES (p_match_id, auth.uid(), true, true, now(), now(), NULL)
  ON CONFLICT (match_id, user_id) DO UPDATE SET
    met_answer = true,
    met_confirmed = true,
    met_answered_at = COALESCE(public.match_rating_prompts.met_answered_at, now()),
    rating_submitted_at = now(),
    next_prompt_at = NULL;

  -- Delete any pending rating prompt row so the client-side
  -- RatingPromptWatcher doesn't re-prompt on next app start.
  DELETE FROM public.pending_rating_prompts
  WHERE user_id = auth.uid() AND match_id = p_match_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.submit_match_rating(uuid, integer, integer, integer, integer, integer) TO authenticated;

COMMIT;