-- Migration: Track per-occurrence coarse locations for rematches so both towns are shown
-- For occurrence 2, show map for occurrence 1 (first town) + map for occurrence 2 (second town).
-- Previously cleanup deleted the old match row and lost its map_center; we now archive it in unmatched_pairs.locations_history.
BEGIN;

ALTER TABLE public.unmatched_pairs ADD COLUMN IF NOT EXISTS locations_history jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Helper to append a location to history (keeps at most 3 entries, one per occurrence)
CREATE OR REPLACE FUNCTION public._append_location_history(p_a uuid, p_b uuid, p_occ int, p_lat double precision, p_lng double precision, p_zoom double precision, p_intent text, p_created timestamptz, p_match_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_hist jsonb; v_exists boolean;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN RETURN; END IF;
  SELECT locations_history INTO v_hist FROM public.unmatched_pairs WHERE user1_id = LEAST(p_a,p_b) AND user2_id = GREATEST(p_a,p_b) FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  -- Avoid duplicate occurrence
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(v_hist) e WHERE (e->>'occurrence')::int = p_occ) INTO v_exists;
  IF v_exists THEN RETURN; END IF;
  v_hist := COALESCE(v_hist, '[]'::jsonb) || jsonb_build_object('occurrence', p_occ, 'map_center_lat', p_lat, 'map_center_lng', p_lng, 'map_zoom', COALESCE(p_zoom,13), 'matched_intent', COALESCE(p_intent,'romantic'), 'created_at', COALESCE(p_created, now()), 'match_id', p_match_id);
  -- Keep sorted by occurrence and limit to 3
  SELECT jsonb_agg(e ORDER BY (e->>'occurrence')::int) INTO v_hist FROM jsonb_array_elements(v_hist) e;
  IF jsonb_array_length(v_hist) > 3 THEN
    SELECT jsonb_agg(e) INTO v_hist FROM (SELECT e FROM jsonb_array_elements(v_hist) e ORDER BY (e->>'occurrence')::int DESC LIMIT 3) s;
    SELECT jsonb_agg(e ORDER BY (e->>'occurrence')::int) INTO v_hist FROM jsonb_array_elements(v_hist) e;
  END IF;
  UPDATE public.unmatched_pairs SET locations_history = v_hist WHERE user1_id = LEAST(p_a,p_b) AND user2_id = GREATEST(p_a,p_b);
END;
$$;

-- Rewrite cleanup to archive the expired match's coarse viewport before deleting
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
        -- Archive current match's location before incrementing
        PERFORM public._append_location_history(v_a, v_b, v_eligible.match_occurrence, v_eligible.map_center_lat, v_eligible.map_center_lng, v_eligible.map_zoom, v_eligible.matched_intent, v_eligible.created_at, v_eligible.id);
        v_new_count := COALESCE(v_hist.expiry_count, 0) + 1;
        v_is_perm := v_new_count >= v_max_occ;
        UPDATE public.unmatched_pairs SET expiry_count = v_new_count, is_permanent = v_is_perm, created_at = GREATEST(unmatched_pairs.created_at, now()), match_type = COALESCE(unmatched_pairs.match_type, v_eligible.match_type), match_id = COALESCE(unmatched_pairs.match_id, v_eligible.id) WHERE user1_id = v_a AND user2_id = v_b;
      END IF;
    END IF;
    DELETE FROM public.chats c WHERE c.match_id = v_eligible.id;
    DELETE FROM public.user_recent_matches urm WHERE urm.match_id = v_eligible.id;
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

-- Update get_user_recent_matches to expose previous_locations from unmatched_pairs
DROP FUNCTION IF EXISTS public.get_user_recent_matches(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  match_type text,
  matched_intent text,
  last_activity_at timestamptz,
  created_at timestamptz,
  chat_start_window_seconds integer,
  chat_start_extension_seconds integer,
  chat_start_extension_count integer,
  expires_at timestamptz,
  has_extended boolean,
  extension_seconds integer,
  match_occurrence integer,
  map_center_lat double precision,
  map_center_lng double precision,
  map_zoom double precision,
  previous_locations jsonb
) AS $$
  SELECT
    urm.match_id,
    urm.other_user_id,
    public.mask_full_name(u.name) as other_name,
    ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
    urm.match_type,
    urm.matched_intent,
    urm.last_activity_at,
    urm.created_at,
    m.chat_start_window_seconds,
    COALESCE(m.chat_start_extension_seconds, 0) as chat_start_extension_seconds,
    COALESCE(m.chat_start_extension_count, 0) as chat_start_extension_count,
    m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, 86400) + COALESCE(m.chat_start_extension_seconds,0)) as expires_at,
    CASE WHEN m.id IS NULL THEN false WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) > 0 ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) > 0 END as has_extended,
    CASE WHEN m.id IS NULL THEN 0 WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) END as extension_seconds,
    COALESCE(m.match_occurrence, 1) as match_occurrence,
    m.map_center_lat,
    m.map_center_lng,
    m.map_zoom,
    COALESCE(up_hist.locations_history, '[]'::jsonb) as previous_locations
  FROM public.user_recent_matches urm
  LEFT JOIN public.matches m ON m.id = urm.match_id
  LEFT JOIN public.users u ON u.id = urm.other_user_id
  LEFT JOIN public.user_profiles up ON up.user_id = urm.other_user_id
  LEFT JOIN public.unmatched_pairs up_hist ON up_hist.user1_id = LEAST(urm.user_id, urm.other_user_id) AND up_hist.user2_id = GREATEST(urm.user_id, urm.other_user_id)
  WHERE urm.user_id = p_user_id
  ORDER BY urm.last_activity_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO anon;

-- Backfill history for the demo pair dd6d20a5 <-> ffc20046 which lost locations due to earlier bug
-- eade9e70 was occurrence 1 with -13.26/-72.26, 1d7074ac was occurrence 1 (should have been 2) with -13.52/-71.99
-- Now b26db4c2 is occurrence 2 with NULL (just fixed). Reconstruct history so both towns show.
INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id, expiry_count, is_permanent, locations_history)
VALUES ('dd6d20a5-cd79-4761-8a74-751acb555b4d','ffc20046-a777-463b-922a-547151aa1455','00000000-0000-0000-0000-000000000000'::uuid, now(), 'proximity', 'b26db4c2-1768-499b-a33f-339da0ed71f9', 1, false,
  jsonb_build_array(
    jsonb_build_object('occurrence', 1, 'map_center_lat', -13.26, 'map_center_lng', -72.26, 'map_zoom', 15, 'matched_intent', 'romantic', 'created_at', '2026-08-30T05:34:27.917234+00', 'match_id', 'eade9e70-1369-4b7a-9fce-dfd1db363b78')
  )
)
ON CONFLICT (user1_id, user2_id) DO UPDATE SET
  expiry_count = GREATEST(unmatched_pairs.expiry_count, 1),
  locations_history = CASE 
    WHEN jsonb_array_length(COALESCE(unmatched_pairs.locations_history,'[]'::jsonb)) = 0
    THEN EXCLUDED.locations_history
    ELSE unmatched_pairs.locations_history
  END;

COMMIT;
