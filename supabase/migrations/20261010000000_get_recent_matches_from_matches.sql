-- Migration: get_user_recent_matches reads directly from matches (drop user_recent_matches dependency)
-- user_recent_matches diverged (e.g. Ingela 08bbc8a0 in matches+chats but not in user_recent_matches),
-- causing RPC to hide valid matches and client flip-flop 1<->2. Single source of truth = matches.
-- Keeps same return shape + previous_locations from unmatched_pairs, ordered by created_at DESC.
BEGIN;

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
    m.id as match_id,
    CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END as other_user_id,
    public.mask_full_name(u.name) as other_name,
    ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
    m.match_type,
    m.matched_intent,
    m.created_at as last_activity_at,
    m.created_at,
    m.chat_start_window_seconds,
    COALESCE(m.chat_start_extension_seconds, 0) as chat_start_extension_seconds,
    COALESCE(m.chat_start_extension_count, 0) as chat_start_extension_count,
    m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, 86400) + COALESCE(m.chat_start_extension_seconds,0)) as expires_at,
    CASE WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) > 0 ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) > 0 END as has_extended,
    CASE WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) END as extension_seconds,
    COALESCE(m.match_occurrence, 1) as match_occurrence,
    m.map_center_lat,
    m.map_center_lng,
    m.map_zoom,
    COALESCE(up_hist.locations_history, '[]'::jsonb) as previous_locations
  FROM public.matches m
  LEFT JOIN public.users u ON u.id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.user_profiles up ON up.user_id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.unmatched_pairs up_hist ON up_hist.user1_id = LEAST(m.user1_id, m.user2_id) AND up_hist.user2_id = GREATEST(m.user1_id, m.user2_id)
  WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id
  ORDER BY m.created_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO anon;

COMMIT;
