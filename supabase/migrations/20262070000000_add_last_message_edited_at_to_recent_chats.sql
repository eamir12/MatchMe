-- Expose the last message's `edited_at` through get_user_recent_chats so the
-- client can tell whether a cached chat-list preview translation was made for
-- the message's current content.
--
-- The chat list keeps its own decrypted preview cache (Hive
-- `recent_chats_$userId`) and, by design, preserves the cached
-- `last_message_translated` across syncs that report no translation, to avoid
-- a "Loading…" flicker. That preservation was keyed on `last_message_id`
-- alone. An edit keeps the same `last_message_id`, so a preview translated for
-- the pre-edit text survived every later sync and was rendered in the Recent
-- Chats row indefinitely.
--
-- `last_message_edited_at` closes that gap: the client stores it next to the
-- cached preview together with the `edited_at` the translation was produced
-- for, and drops the cache whenever the two no longer match — the same
-- invariant already enforced for messages via `translated_source_edited_at`.
--
-- `last_message_translated_source_edited_at` is that server-side marker itself,
-- so the client can apply the same check before decrypting the stored
-- translation instead of trusting the blob unconditionally. It is normally
-- redundant — `edit_chat_message` NULLs the translation and translate-proxy
-- refuses to skip a marker-mismatched row — but it closes the window where an
-- edit and a sync race each other.
--
-- Plain metadata already visible to both match participants; no
-- plaintext-derived data.

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
  last_message_translated_source_edited_at timestamptz
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
         cm.translated_source_edited_at as last_message_translated_source_edited_at
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
