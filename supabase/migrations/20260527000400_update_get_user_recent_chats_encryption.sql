-- Migration: Update get_user_recent_chats to include encryption columns
-- Purpose: Ensure the Flutter app has all the necessary data to decrypt message previews for notifications and the chat list.

BEGIN;

DROP FUNCTION IF EXISTS public.get_user_recent_chats(uuid, int);

CREATE OR REPLACE FUNCTION public.get_user_recent_chats(p_user_id uuid, p_limit int DEFAULT 20)
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
  last_message_wrapped_keys jsonb
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
         cm.wrapped_keys as last_message_wrapped_keys
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

COMMIT;
