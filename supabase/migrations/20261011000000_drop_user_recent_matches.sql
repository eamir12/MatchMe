-- Migration: Drop user_recent_matches (RPC now reads matches directly, single source of truth)
-- Verified: no Dart reads table directly (only via get_user_recent_matches RPC which now SELECTs matches).
-- Testing mode, single user - safe to finalize.
BEGIN;

-- 1) Rewrite cleanup_expired_matches without user_recent_matches delete
DROP FUNCTION IF EXISTS public.cleanup_expired_matches(timestamptz, int);
CREATE OR REPLACE FUNCTION public.cleanup_expired_matches(p_cutoff timestamptz, p_limit int DEFAULT 500)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_window_cfg int;
  v_max_occ int;
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
  v_max_occ := public._get_max_match_occurrence();
  FOR v_eligible IN
    SELECT m.id, m.user1_id, m.user2_id, m.match_type, m.match_occurrence, m.map_center_lat, m.map_center_lng, m.map_zoom, m.matched_intent, m.created_at
    FROM public.matches m
    WHERE m.match_type IN ('proximity','event','co_motion')
      AND m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, v_window_cfg) + COALESCE(m.chat_start_extension_seconds, 0)) < now()
    ORDER BY m.created_at LIMIT COALESCE(p_limit, 500)
  LOOP
    IF EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id LIMIT 1) THEN CONTINUE; END IF;
    v_a := LEAST(v_eligible.user1_id, v_eligible.user2_id);
    v_b := GREATEST(v_eligible.user1_id, v_eligible.user2_id);
    SELECT expiry_count, is_permanent, locations_history INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b FOR UPDATE;
    IF NOT FOUND THEN
      v_new_count := 1;
      v_is_perm := v_new_count >= v_max_occ;
      INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id, expiry_count, is_permanent, locations_history)
      VALUES (v_a, v_b, '00000000-0000-0000-0000-000000000000'::uuid, now(), v_eligible.match_type, v_eligible.id, v_new_count, v_is_perm,
        CASE WHEN v_eligible.map_center_lat IS NOT NULL AND v_eligible.map_center_lng IS NOT NULL
          THEN jsonb_build_array(jsonb_build_object('occurrence', v_eligible.match_occurrence, 'map_center_lat', v_eligible.map_center_lat, 'map_center_lng', v_eligible.map_center_lng, 'map_zoom', COALESCE(v_eligible.map_zoom,13), 'matched_intent', v_eligible.matched_intent, 'created_at', v_eligible.created_at, 'match_id', v_eligible.id))
          ELSE '[]'::jsonb END);
    ELSE
      IF v_hist.is_permanent THEN NULL;
      ELSE
        PERFORM public._append_location_history(v_a, v_b, v_eligible.match_occurrence, v_eligible.map_center_lat, v_eligible.map_center_lng, v_eligible.map_zoom, v_eligible.matched_intent, v_eligible.created_at, v_eligible.id);
        v_new_count := COALESCE(v_hist.expiry_count, 0) + 1;
        v_is_perm := v_new_count >= v_max_occ;
        UPDATE public.unmatched_pairs SET expiry_count = v_new_count, is_permanent = v_is_perm, created_at = GREATEST(unmatched_pairs.created_at, now()), match_type = COALESCE(unmatched_pairs.match_type, v_eligible.match_type), match_id = COALESCE(unmatched_pairs.match_id, v_eligible.id) WHERE user1_id = v_a AND user2_id = v_b;
      END IF;
    END IF;
    DELETE FROM public.chats c WHERE c.match_id = v_eligible.id;
    DELETE FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id;
    DELETE FROM public.matches m WHERE m.id = v_eligible.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN COALESCE(v_count, 0);
END;
$$;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_matches(timestamptz, int) TO service_role;

-- 2) Rewrite unmatch_from_system_match without user_recent_matches (and other dropped tables)
DROP FUNCTION IF EXISTS public.unmatch_from_system_match(uuid);
CREATE OR REPLACE FUNCTION public.unmatch_from_system_match(p_match_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_user1_id uuid;
  v_user2_id uuid;
  v_match_type text;
  v_a uuid;
  v_b uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT m.user1_id, m.user2_id, m.match_type INTO v_user1_id, v_user2_id, v_match_type FROM public.matches m WHERE m.id = p_match_id;
  IF v_user1_id IS NULL OR v_user2_id IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF v_user_id <> v_user1_id AND v_user_id <> v_user2_id THEN RAISE EXCEPTION 'Forbidden'; END IF;
  IF v_match_type NOT IN ('proximity','event','co_motion') THEN RAISE EXCEPTION 'Match type not allowed'; END IF;
  v_a := LEAST(v_user1_id, v_user2_id);
  v_b := GREATEST(v_user1_id, v_user2_id);
  INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id, expiry_count, is_permanent)
  VALUES (v_a, v_b, v_user_id, now(), v_match_type, p_match_id, 0, true)
  ON CONFLICT (user1_id, user2_id) DO UPDATE SET created_by = EXCLUDED.created_by, created_at = GREATEST(unmatched_pairs.created_at, EXCLUDED.created_at), match_type = COALESCE(unmatched_pairs.match_type, EXCLUDED.match_type), match_id = COALESCE(unmatched_pairs.match_id, EXCLUDED.match_id), is_permanent = true;
  DELETE FROM public.chats WHERE match_id = p_match_id;
  DELETE FROM public.chat_messages WHERE match_id = p_match_id;
  DELETE FROM public.matches WHERE id = p_match_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.unmatch_from_system_match(uuid) TO authenticated;

-- 3) Drop trigger + writer functions
DROP TRIGGER IF EXISTS trg_handle_new_match ON public.matches;
DROP FUNCTION IF EXISTS public.handle_new_match();
DROP FUNCTION IF EXISTS public.upsert_user_recent_match(uuid, uuid, uuid, text, text, timestamptz, timestamptz);

-- 4) Drop RLS policies then table
DROP POLICY IF EXISTS "Users can read own recent matches" ON public.user_recent_matches;
DROP POLICY IF EXISTS "Service role can access all recent matches" ON public.user_recent_matches;
DROP TABLE IF EXISTS public.user_recent_matches CASCADE;

COMMIT;
