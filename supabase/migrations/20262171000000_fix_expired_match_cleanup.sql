-- Fix starvation in cleanup_expired_matches.
--
-- The previous body selected the oldest p_limit expired matches and then
-- `CONTINUE`d for any match that had chat messages. Once the oldest 500
-- expired matches were all "chat started" rows, the function never looked
-- past them again: every tick re-read the same 500 rows and deleted nothing.
--
-- The "has messages" filter now happens in SQL, so LIMIT applies to rows
-- that are actually deletable. The per-row re-check is kept as a race guard
-- for a message arriving between selection and deletion.

BEGIN;

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
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg
  FROM public.app_config
  WHERE config_key = 'matches.chat_start_window_seconds'
  LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <= 0 THEN v_window_cfg := 86400; END IF;
  v_max_occ := public._get_max_match_occurrence();

  FOR v_eligible IN
    SELECT m.id, m.user1_id, m.user2_id, m.match_type, m.match_occurrence,
           m.map_center_lat, m.map_center_lng, m.map_zoom, m.matched_intent, m.created_at
    FROM public.matches m
    WHERE m.match_type IN ('proximity','event','co_motion')
      AND m.created_at + make_interval(
            secs => COALESCE(m.chat_start_window_seconds, v_window_cfg)
                  + COALESCE(m.chat_start_extension_seconds, 0)
          ) < now()
      AND NOT EXISTS (
        SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = m.id
      )
    ORDER BY m.created_at
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000)
  LOOP
    -- A message may have arrived after the candidate query ran.
    IF EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id LIMIT 1) THEN
      CONTINUE;
    END IF;

    v_a := LEAST(v_eligible.user1_id, v_eligible.user2_id);
    v_b := GREATEST(v_eligible.user1_id, v_eligible.user2_id);
    SELECT expiry_count, is_permanent, locations_history
    INTO v_hist
    FROM public.unmatched_pairs
    WHERE user1_id = v_a AND user2_id = v_b
    FOR UPDATE;

    IF NOT FOUND THEN
      v_new_count := 1;
      v_is_perm := v_new_count >= v_max_occ;
      INSERT INTO public.unmatched_pairs (
        user1_id, user2_id, created_by, created_at, match_type, match_id,
        expiry_count, is_permanent, locations_history
      )
      VALUES (
        v_a, v_b, '00000000-0000-0000-0000-000000000000'::uuid, now(),
        v_eligible.match_type, v_eligible.id, v_new_count, v_is_perm,
        CASE WHEN v_eligible.map_center_lat IS NOT NULL AND v_eligible.map_center_lng IS NOT NULL
          THEN jsonb_build_array(jsonb_build_object(
            'occurrence', v_eligible.match_occurrence,
            'map_center_lat', v_eligible.map_center_lat,
            'map_center_lng', v_eligible.map_center_lng,
            'map_zoom', COALESCE(v_eligible.map_zoom, 13),
            'matched_intent', v_eligible.matched_intent,
            'created_at', v_eligible.created_at,
            'match_id', v_eligible.id
          ))
          ELSE '[]'::jsonb END
      );
    ELSE
      IF v_hist.is_permanent THEN
        NULL;
      ELSE
        PERFORM public._append_location_history(
          v_a, v_b, v_eligible.match_occurrence, v_eligible.map_center_lat,
          v_eligible.map_center_lng, v_eligible.map_zoom,
          v_eligible.matched_intent, v_eligible.created_at, v_eligible.id
        );
        v_new_count := COALESCE(v_hist.expiry_count, 0) + 1;
        v_is_perm := v_new_count >= v_max_occ;
        UPDATE public.unmatched_pairs
        SET expiry_count = v_new_count,
            is_permanent = v_is_perm,
            created_at = GREATEST(unmatched_pairs.created_at, now()),
            match_type = COALESCE(unmatched_pairs.match_type, v_eligible.match_type),
            match_id = COALESCE(unmatched_pairs.match_id, v_eligible.id)
        WHERE user1_id = v_a AND user2_id = v_b;
      END IF;
    END IF;

    DELETE FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id;
    DELETE FROM public.chats c WHERE c.match_id = v_eligible.id;
    -- Legacy per-match tables that some environments still have. Each was
    -- dropped by a later migration; a direct reference would make the whole
    -- function fail at runtime with "relation does not exist".
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_recent_matches') THEN
      EXECUTE 'DELETE FROM public.user_recent_matches WHERE match_id = $1' USING v_eligible.id;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_recent_chats') THEN
      EXECUTE 'DELETE FROM public.user_recent_chats WHERE match_id = $1' USING v_eligible.id;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'match_chat_extensions') THEN
      EXECUTE 'DELETE FROM public.match_chat_extensions WHERE match_id = $1' USING v_eligible.id;
    END IF;
    DELETE FROM public.matches m WHERE m.id = v_eligible.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN COALESCE(v_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_matches(timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_matches(timestamptz, int) TO service_role;

-- The candidate query orders expired matches by age. Without this, the planner
-- reads the whole matches table and sorts on every minute tick.
CREATE INDEX IF NOT EXISTS idx_matches_expired_sweep
  ON public.matches (created_at)
  WHERE match_type IN ('proximity', 'event', 'co_motion');

-- chats has PK (user_id, match_id); deleting by match_id alone was a seq scan.
CREATE INDEX IF NOT EXISTS idx_chats_match_id
  ON public.chats (match_id);

COMMIT;
