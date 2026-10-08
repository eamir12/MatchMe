-- Migration: chat archive
--
-- Adds a per-user "archived" flag to the chats list. public.chats holds one
-- row per (user, match), so archived_at on that row archives the chat for
-- exactly one side of the conversation — the other participant's row is
-- untouched. Archiving is a display concern only: the row keeps receiving
-- updates from the chat-message triggers (unread counts, previews) and the
-- chat still receives notifications; nothing is muted or deleted.
--
-- get_user_recent_chats keeps returning archived rows and exposes the
-- timestamp so the client can split its list into "Chats" and "Archived"
-- views from a single local cache (the client filter, not a server filter,
-- because the cache is offline-first and the archived view reads the same
-- rows). get_user_recent_chats's LIMIT is applied over all rows including
-- archived ones; the default client limit (50) makes an archived backlog
-- crowding out active chats a non-issue in practice.
--
-- The upsert trigger (upsert_chat_row / handle_chat_message_for_chats) does
-- not touch archived_at, so an archive decision survives new messages.

BEGIN;

ALTER TABLE public.chats
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- The chats list is read per user, most recently active first; this index
-- also serves the archived split.
CREATE INDEX IF NOT EXISTS idx_chats_user_active
  ON public.chats (user_id, last_message_at DESC NULLS LAST)
  WHERE archived_at IS NULL;

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
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO anon;

COMMENT ON FUNCTION public.get_user_recent_chats(uuid, int) IS
  'Chats for a user, newest activity first. archived_at is set when the user '
  'archived the chat; the client splits its list into active and archived '
  'views from this column. Archiving does not mute: message triggers keep '
  'updating the row and notifications flow as normal.';

COMMIT;
