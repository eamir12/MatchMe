-- Migration: Make check_all_due_rating_prompts read initial delay from app_config + update to 3 days

BEGIN;

-- =========================
-- 1) Update app_config to 3 days
-- =========================
UPDATE public.app_config
SET config_value = '259200',
    description  = 'Delay after match creation before first meet prompt (default 3 days)'
WHERE config_key = 'ratings.prompt_initial_delay_seconds';

-- =========================
-- 2) Re-create check_all_due_rating_prompts without parameter
--    Reads ratings.prompt_initial_delay_seconds from app_config on each run.
-- =========================
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
  --     and don't have a match_rating_prompts row yet, and whose creation time
  --     exceeds the configured initial delay.
  INSERT INTO public.match_rating_prompts (match_id, user_id, next_prompt_at)
  SELECT
    m.id,
    u.id,
    (m.created_at + make_interval(secs => v_initial_delay_seconds))
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
    AND (m.created_at + make_interval(secs => v_initial_delay_seconds)) <= now()
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
-- 3) Update pg_cron job to call the new parameterless signature
-- =========================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'check-due-rating-prompts') THEN
      PERFORM cron.unschedule('check-due-rating-prompts');
    END IF;
    PERFORM cron.schedule(
      'check-due-rating-prompts',
      '*/5 * * * *',
      'SELECT public.check_all_due_rating_prompts()'
    );
  END IF;
END $$;

COMMIT;
