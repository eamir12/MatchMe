-- Fix get_user_recent_chats to handle string "null" values in content_translated
-- This ensures the sync fallback in Flutter gets proper translation data

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
         CASE 
             WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
             ELSE NULL
         END as last_message_translated
  FROM public.chats c
  LEFT JOIN public.users u ON c.other_user_id = u.id
  LEFT JOIN public.chat_messages cm ON cm.id = c.last_message_id
  WHERE c.user_id = p_user_id
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO anon;
