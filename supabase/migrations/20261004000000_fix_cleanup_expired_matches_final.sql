-- Migration: Fix cleanup_expired_matches to not reference dropped user_recent_chats table
-- The previous migration 20261003000000 still deleted from public.user_recent_chats which
-- was dropped in 20260101162000, causing cron to fail with "relation public.user_recent_chats does not exist"
-- and leaving expired matches visible in UI.
-- This migration recreates cleanup_expired_matches without that CTE and ensures
-- extension-aware expiry is used.

BEGIN;

DROP FUNCTION IF EXISTS public.cleanup_expired_matches(timestamptz, int);

CREATE OR REPLACE FUNCTION public.cleanup_expired_matches(p_cutoff timestamptz, p_limit int DEFAULT 500)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_window_cfg int;
  v_eligible RECORD;
  v_a uuid;
  v_b uuid;
  v_hist RECORD;
  v_new_count int;
  v_is_perm boolean;
  v_count int := 0;
BEGIN
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <= 0 THEN v_window_cfg := 86400; END IF;
  FOR v_eligible IN
    SELECT m.id, m.user1_id, m.user2_id, m.match_type, m.match_occurrence
    FROM public.matches m
    WHERE m.match_type IN ('proximity','event','co_motion')
      AND m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, v_window_cfg) + COALESCE(m.chat_start_extension_seconds, 0)) < now()
    ORDER BY m.created_at LIMIT COALESCE(p_limit, 500)
  LOOP
    IF EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id LIMIT 1) THEN CONTINUE; END IF;
    v_a := LEAST(v_eligible.user1_id, v_eligible.user2_id);
    v_b := GREATEST(v_eligible.user1_id, v_eligible.user2_id);
    SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b FOR UPDATE;
    IF NOT FOUND THEN
      INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id, expiry_count, is_permanent)
      VALUES (v_a, v_b, '00000000-0000-0000-0000-000000000000'::uuid, now(), v_eligible.match_type, v_eligible.id, 1, false);
    ELSE
      IF v_hist.is_permanent THEN NULL;
      ELSE
        v_new_count := COALESCE(v_hist.expiry_count, 0) + 1;
        v_is_perm := v_new_count >= 3;
        UPDATE public.unmatched_pairs SET expiry_count = v_new_count, is_permanent = v_is_perm, created_at = GREATEST(unmatched_pairs.created_at, now()), match_type = COALESCE(unmatched_pairs.match_type, v_eligible.match_type), match_id = COALESCE(unmatched_pairs.match_id, v_eligible.id) WHERE user1_id = v_a AND user2_id = v_b;
      END IF;
    END IF;
    DELETE FROM public.chats c WHERE c.match_id = v_eligible.id;
    DELETE FROM public.user_recent_matches urm WHERE urm.match_id = v_eligible.id;
    -- public.user_recent_chats was dropped in 20260101162000 (consolidated to chats). Keep conditional delete for idempotency if table somehow exists in older env.
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_recent_chats') THEN
      EXECUTE 'DELETE FROM public.user_recent_chats WHERE match_id = $1' USING v_eligible.id;
    END IF;
    DELETE FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='match_chat_extensions') THEN
      EXECUTE 'DELETE FROM public.match_chat_extensions WHERE match_id = $1' USING v_eligible.id;
    END IF;
    DELETE FROM public.matches m WHERE m.id = v_eligible.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN COALESCE(v_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_matches(timestamptz, int) TO service_role;

COMMIT;
