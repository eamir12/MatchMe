-- Migration: Require at least one chat message before rating prompt eligibility
-- Prevents users from rating each other if they never actually chatted.

BEGIN;

-- =========================
-- 1) get_due_match_rating_prompts: add chat_messages check
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
         m.created_at AS created_at,
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
  SELECT um.match_id, p_user_id AS user_id,
         (um.created_at + make_interval(secs => p_initial_delay_seconds)) AS next_prompt_at
  FROM user_matches um
  LEFT JOIN public.match_rating_prompts mrp
    ON mrp.match_id = um.match_id AND mrp.user_id = p_user_id
  WHERE mrp.match_id IS NULL
    AND (um.created_at + make_interval(secs => p_initial_delay_seconds)) <= now()
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
       um.created_at AS match_created_at,
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
-- 2) check_all_due_rating_prompts: add chat_messages check
-- =========================

CREATE OR REPLACE FUNCTION public.check_all_due_rating_prompts(
  p_initial_delay_seconds integer DEFAULT 72000
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 5a) Insert initial prompt rows for matches that have at least one message
  --     and don't have a match_rating_prompts row yet, and whose creation time
  --     exceeds the initial delay.
  INSERT INTO public.match_rating_prompts (match_id, user_id, next_prompt_at)
  SELECT
    m.id,
    u.id,
    (m.created_at + make_interval(secs => p_initial_delay_seconds))
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
    AND (m.created_at + make_interval(secs => p_initial_delay_seconds)) <= now()
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

COMMIT;
