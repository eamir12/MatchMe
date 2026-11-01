-- Migration: watermark-aware list RPCs (12.1 client delta sync)
--
-- The proven startup delta fetches only rows whose updated_at moved past the
-- client's watermark, instead of re-downloading the whole list. The client
-- cannot read the display shape directly (masked names, profile photos,
-- encrypted last-message columns), so the two list RPCs gain an optional
-- p_since watermark:
--
--   p_since IS NULL  -> the full list, exactly as before (old app builds keep
--                       calling the same function by name; the parameter
--                       defaults to NULL).
--   p_since NOT NULL -> only rows with updated_at > p_since.
--
-- The client stores max(updated_at) from the returned rows as its next
-- watermark and falls back to a full fetch when a delta reaches p_limit or
-- the RPC signature is not deployed yet. Deletions are not visible to a
-- watermark; the client keeps its deferred full reconcile for those.
--
-- get_user_recent_matches also has to expose updated_at for the client to
-- advance its watermark. RETURN TABLE is part of the signature, so the
-- function must be dropped and recreated; the extra key is additive for
-- PostgREST clients.
--
-- This preserves the latest definitions: the ordering tiebreaker from
-- 20262106000000 (chats), the identity guard from 20262202000000 (matches),
-- the invoker search_path pin from 20262209000000 (chats) and the
-- authenticated/service_role-only ACL from 20262201000000 (matches).
--
-- Rollback: drop the 3-arg functions and recreate the 2-arg ones from
-- 20262106000000 (chats) and 20262202000000 (matches), then re-apply the
-- get_user_recent_chats ALTER from 20262209000000.

BEGIN;

DROP FUNCTION IF EXISTS public.get_user_recent_chats(uuid, int);

CREATE OR REPLACE FUNCTION public.get_user_recent_chats(
  p_user_id uuid,
  p_limit int DEFAULT 20,
  p_since timestamptz DEFAULT NULL
)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  updated_at timestamptz,
  translation_enabled boolean,
  translation_language text,
  last_message_id uuid,
  last_message_sender_id uuid,
  last_message_translated text,
  last_message_source_language text,
  last_message_target_language text,
  last_message_encryption_scheme text,
  last_message_sender_key_id uuid,
  last_message_recipient_key_id uuid,
  last_message_recipient_id uuid,
  last_message_content_original_encrypted text,
  last_message_content_original_nonce text,
  last_message_content_translated_encrypted text,
  last_message_content_translated_nonce text,
  last_message_wrapped_keys jsonb,
  matched_intent text,
  last_message_edited_at timestamptz,
  last_message_translated_source_edited_at timestamptz,
  match_type text,
  archived_at timestamptz
) AS $$
  SELECT c.match_id, c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
         c.last_message_preview, c.last_message_at,
         c.unread_count, c.updated_at,
         c.translation_enabled, c.translation_language,
         c.last_message_id,
         COALESCE(cm.sender_id, c.other_user_id) as last_message_sender_id,
         CASE
             WHEN cm.content_translated_encrypted IS NOT NULL
                  AND cm.content_translated_encrypted != ''
             THEN cm.content_translated_encrypted
             ELSE NULL
         END as last_message_translated,
         cm.detected_source_language as last_message_source_language,
         cm.translated_target_language as last_message_target_language,
         cm.encryption_scheme as last_message_encryption_scheme,
         cm.sender_key_id as last_message_sender_key_id,
         cm.recipient_key_id as last_message_recipient_key_id,
         cm.recipient_id as last_message_recipient_id,
         cm.content_original_encrypted as last_message_content_original_encrypted,
         cm.content_original_nonce as last_message_content_original_nonce,
         cm.content_translated_encrypted as last_message_content_translated_encrypted,
         cm.content_translated_nonce as last_message_content_translated_nonce,
         cm.wrapped_keys as last_message_wrapped_keys,
         m.matched_intent as matched_intent,
         cm.edited_at as last_message_edited_at,
         cm.translated_source_edited_at as last_message_translated_source_edited_at,
         m.match_type as match_type,
         c.archived_at as archived_at
  FROM public.chats c
  INNER JOIN public.matches m ON m.id = c.match_id
  LEFT JOIN public.users u ON c.other_user_id = u.id
  LEFT JOIN public.user_profiles up ON up.user_id = c.other_user_id
  LEFT JOIN public.chat_messages cm ON cm.id = c.last_message_id
  WHERE c.user_id = p_user_id
    AND (p_since IS NULL OR c.updated_at > p_since)
  ORDER BY GREATEST(c.last_message_at, c.updated_at) DESC NULLS LAST,
           c.match_id
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SET search_path = '';

REVOKE ALL ON FUNCTION public.get_user_recent_chats(uuid, int, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int, timestamptz) TO anon;

COMMENT ON FUNCTION public.get_user_recent_chats(uuid, int, timestamptz) IS
  'Chats for a user, most recent activity first (last_message_at/updated_at, '
  'match_id tiebreaker for a stable page). archived_at is set when the user '
  'archived the chat; the client splits its list into active and archived '
  'views from this column. Archiving does not mute: message triggers keep '
  'updating the row and notifications flow as normal. p_since NULL returns '
  'the full list; otherwise only rows with updated_at > p_since (bounded by '
  'p_limit) are returned for delta sync.';

DROP FUNCTION IF EXISTS public.get_user_recent_matches(uuid, int);

CREATE OR REPLACE FUNCTION public.get_user_recent_matches(
  p_user_id uuid,
  p_limit integer DEFAULT 20,
  p_since timestamptz DEFAULT NULL
)
 RETURNS TABLE(match_id uuid, other_user_id uuid, other_name text, other_photos text[], match_type text, matched_intent text, last_activity_at timestamp with time zone, created_at timestamp with time zone, chat_start_window_seconds integer, chat_start_extension_seconds integer, chat_start_extension_count integer, expires_at timestamp with time zone, has_extended boolean, extension_seconds integer, match_occurrence integer, map_center_lat double precision, map_center_lng double precision, map_zoom double precision, previous_locations jsonb, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
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
    COALESCE(up_hist.locations_history, '[]'::jsonb) as previous_locations,
    m.updated_at
  FROM public.matches m
  LEFT JOIN public.users u ON u.id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.user_profiles up ON up.user_id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.unmatched_pairs up_hist ON up_hist.user1_id = LEAST(m.user1_id, m.user2_id) AND up_hist.user2_id = GREATEST(m.user1_id, m.user2_id)
  WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
    AND (p_since IS NULL OR m.updated_at > p_since)
  ORDER BY m.created_at DESC, m.id
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_user_recent_matches(uuid, integer, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, integer, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, integer, timestamptz) TO service_role;

COMMENT ON FUNCTION public.get_user_recent_matches(uuid, integer, timestamptz) IS
  'Matches for a user with the display shape the app caches. p_since NULL '
  'returns the full list; otherwise only rows with updated_at > p_since '
  '(bounded by p_limit) are returned for delta sync. updated_at is exposed '
  'so the client can advance its watermark.';

COMMIT;
