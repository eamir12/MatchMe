-- Drop existing functions first (required when changing return types)
DROP FUNCTION IF EXISTS public.get_user_recent_matches(uuid, int);
DROP FUNCTION IF EXISTS public.get_user_recent_chats(uuid, int);

-- Simplified Recent Matches Query
-- Get top 5 matches for a user, ordered by created_at (most recent first)
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit int DEFAULT 5)
RETURNS TABLE (
  id uuid,
  user1_id uuid,
  user2_id uuid,
  matched_intent text,
  created_at timestamptz,
  event_id uuid,
  event_name text,
  event_link text
) AS $$
  SELECT m.id, m.user1_id, m.user2_id, m.matched_intent, m.created_at,
         m.event_id, e.event_name, e.event_link
  FROM public.matches m
  LEFT JOIN public.events e ON m.event_id = e.id
  WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id
  ORDER BY m.created_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- Simplified Recent Chats Query
-- Get top 5 chats for a user, ordered by updated_at (most recently updated first)
-- Still includes essential user information but simplified
CREATE OR REPLACE FUNCTION public.get_user_recent_chats(p_user_id uuid, p_limit int DEFAULT 5)
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
  last_message_translated text
) AS $$
  SELECT c.match_id, c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         u.photos::text[] as other_photos,
         c.last_message_preview, c.last_message_at,
         c.unread_count, c.updated_at,
         c.translation_enabled, c.translation_language,
         c.last_message_id,
         COALESCE(cm.sender_id, c.other_user_id) as last_message_sender_id,
         cm.content_translated as last_message_translated
  FROM public.chats c
  LEFT JOIN public.users u ON c.other_user_id = u.id
  LEFT JOIN public.chat_messages cm ON cm.id = c.last_message_id
  WHERE c.user_id = p_user_id
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, int) TO anon;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO anon;
