-- Migration: Anchor event-match rating prompts to the shared event's start time
--
-- Previously every match's first rating prompt became due at
-- matches.created_at + ratings.prompt_initial_delay_seconds. For event-based
-- matches that is wrong: the match is created days or weeks before the event, so
-- users were asked "did you meet in real life?" about an event that had not
-- happened yet.
--
-- Event matches now anchor the initial delay on events.start_time. Every other
-- match type (proximity, co_motion, manual_test) keeps matches.created_at.
-- The chat_messages eligibility requirement is unchanged.

BEGIN;

-- =========================
-- 1) Shared anchor helper
-- =========================
-- Returns the time a match's first rating prompt becomes eligible.
-- Event matches use events.start_time; all other match types use created_at.
-- Falls back to created_at when an event match has no resolvable event start
-- (missing event row or null start_time) so prompts can never be stranded.
CREATE OR REPLACE FUNCTION public._match_rating_prompt_due_at(
  p_match_row public.matches,
  p_initial_delay_seconds integer
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT e.start_time + make_interval(secs => p_initial_delay_seconds)
      FROM public.events e
      WHERE p_match_row.match_type = 'event'
        AND p_match_row.event_id = e.id
        AND e.start_time IS NOT NULL
      LIMIT 1
    ),
    p_match_row.created_at + make_interval(secs => p_initial_delay_seconds)
  );
$$;

-- =========================
-- 2) check_all_due_rating_prompts: use the anchor for step 5a
-- =========================
-- 5b is unchanged: it only reads mrp.next_prompt_at, which 5a now sets to the
-- event-anchored due time.
CREATE OR REPLACE FUNCTION public.check_all_due_rating_prompts()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_initial_delay_seconds integer;
BEGIN
  -- Read dynamic delay from app_config (fallback 259200 = 3 days)
  SELECT COALESCE(
    (SELECT config_value::integer FROM public.app_config WHERE config_key = 'ratings.prompt_initial_delay_seconds'),
    259200
  ) INTO v_initial_delay_seconds;

  -- 5a) Insert initial prompt rows for matches that have at least one message
  --     and don't have a match_rating_prompts row yet, and whose anchor time
  --     (event start for event matches, creation time otherwise) plus the
  --     configured initial delay is in the past.
  INSERT INTO public.match_rating_prompts (match_id, user_id, next_prompt_at)
  SELECT
    m.id,
    u.id,
    public._match_rating_prompt_due_at(m, v_initial_delay_seconds)
  FROM public.matches m
  CROSS JOIN LATERAL (VALUES (m.user1_id), (m.user2_id)) AS u(id)
  WHERE EXISTS (
    SELECT 1 FROM public.chat_messages cm
    WHERE cm.match_id = m.id
    LIMIT 1
  )
    AND NOT EXISTS (
      SELECT 1 FROM public.match_rating_prompts mrp
      WHERE mrp.match_id = m.id AND mrp.user_id = u.id
    )
    AND public._match_rating_prompt_due_at(m, v_initial_delay_seconds) <= now()
  ON CONFLICT (match_id, user_id) DO NOTHING;

  -- 5b) Insert pending prompt rows for every due (unrated) prompt that has
  --     at least one message and hasn't already been queued.
  INSERT INTO public.pending_rating_prompts (user_id, match_id, other_user_id, other_name, match_created_at)
  SELECT
    mrp.user_id,
    mrp.match_id,
    CASE WHEN m.user1_id = mrp.user_id THEN m.user2_id ELSE m.user1_id END,
    public.mask_full_name(u.name),
    m.created_at
  FROM public.match_rating_prompts mrp
  JOIN public.matches m ON m.id = mrp.match_id
  JOIN public.users u
    ON u.id = CASE WHEN m.user1_id = mrp.user_id THEN m.user2_id ELSE m.user1_id END
  WHERE mrp.rating_submitted_at IS NULL
    AND mrp.next_prompt_at IS NOT NULL
    AND mrp.next_prompt_at <= now()
    AND EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = mrp.match_id
      LIMIT 1
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.pending_rating_prompts prp
      WHERE prp.user_id = mrp.user_id AND prp.match_id = mrp.match_id
    );
END;
$$;

-- =========================
-- 3) get_due_match_rating_prompts: same anchor (kept consistent)
-- =========================
DROP FUNCTION IF EXISTS public.get_due_match_rating_prompts(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.get_due_match_rating_prompts(
  p_user_id uuid,
  p_initial_delay_seconds integer,
  p_limit integer DEFAULT 1
)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  match_created_at timestamptz,
  other_user_met_confirmed boolean,
  self_met_confirmed boolean,
  next_prompt_at timestamptz
) AS $$
WITH user_matches AS (
  SELECT m.id AS match_id,
         m.created_at AS match_created_at,
         m AS match_row,
         CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END AS other_user_id
  FROM public.matches m
  WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
    AND EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = m.id
      LIMIT 1
    )
),
due_missing_rows AS (
  SELECT um.match_id AS match_id,
         p_user_id AS user_id,
         public._match_rating_prompt_due_at(um.match_row, p_initial_delay_seconds) AS next_prompt_at
  FROM user_matches um
  LEFT JOIN public.match_rating_prompts mrp
    ON mrp.match_id = um.match_id AND mrp.user_id = p_user_id
  WHERE mrp.match_id IS NULL
    AND public._match_rating_prompt_due_at(um.match_row, p_initial_delay_seconds) <= now()
),
inserted AS (
  INSERT INTO public.match_rating_prompts (match_id, user_id, next_prompt_at)
  SELECT match_id, user_id, next_prompt_at
  FROM due_missing_rows
  ON CONFLICT (match_id, user_id) DO NOTHING
  RETURNING match_id
),
due_prompts AS (
  SELECT mrp.match_id,
         mrp.user_id,
         mrp.next_prompt_at,
         mrp.met_confirmed AS self_met_confirmed
  FROM public.match_rating_prompts mrp
  WHERE mrp.user_id = p_user_id
    AND mrp.rating_submitted_at IS NULL
    AND mrp.next_prompt_at IS NOT NULL
    AND mrp.next_prompt_at <= now()
    AND EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = mrp.match_id
      LIMIT 1
    )
)
SELECT dp.match_id,
       um.other_user_id,
       public.mask_full_name(u.name) AS other_name,
       um.match_created_at AS match_created_at,
       COALESCE(otherp.met_confirmed, false) AS other_user_met_confirmed,
       dp.self_met_confirmed,
       dp.next_prompt_at
FROM due_prompts dp
JOIN user_matches um ON um.match_id = dp.match_id
LEFT JOIN public.users u ON u.id = um.other_user_id
LEFT JOIN public.match_rating_prompts otherp
  ON otherp.match_id = dp.match_id AND otherp.user_id = um.other_user_id
ORDER BY dp.next_prompt_at ASC
LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_due_match_rating_prompts(uuid, integer, integer) TO authenticated;

-- =========================
-- 4) Backfill event-match rows seeded with the old created_at anchor
-- =========================
-- Only rows still sitting on their original initial anchor are touched: an
-- answered row (met_answered_at IS NOT NULL) holds a repeat schedule from
-- set_match_met_answer, and a submitted row is finished. Both are left alone.
DO $$
DECLARE
  v_initial_delay_seconds integer;
BEGIN
  SELECT COALESCE(
    (SELECT config_value::integer FROM public.app_config WHERE config_key = 'ratings.prompt_initial_delay_seconds'),
    259200
  ) INTO v_initial_delay_seconds;

  UPDATE public.match_rating_prompts mrp
  SET next_prompt_at = public._match_rating_prompt_due_at(m, v_initial_delay_seconds)
  FROM public.matches m
  WHERE m.id = mrp.match_id
    AND m.match_type = 'event'
    AND mrp.rating_submitted_at IS NULL
    AND mrp.met_answered_at IS NULL
    AND mrp.next_prompt_at IS NOT NULL
    AND mrp.next_prompt_at IS DISTINCT FROM public._match_rating_prompt_due_at(m, v_initial_delay_seconds);
END;
$$;

COMMIT;
