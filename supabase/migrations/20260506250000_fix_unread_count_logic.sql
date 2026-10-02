-- Migration: Fix unread_count logic in upsert_chat_row
-- Purpose: Fix the bug where senders get unread_count incremented even though p_unread_increment=0
-- The function was ignoring p_unread_increment and always setting unread_count to 1 when it was 0

-- Replace the upsert_chat_row function with corrected logic
CREATE OR REPLACE FUNCTION public.upsert_chat_row(
  p_user_id uuid,
  p_match_id uuid,
  p_other_user_id uuid,
  p_last_message_id uuid,
  p_last_message_preview text,
  p_last_message_at timestamptz,
  p_unread_increment integer DEFAULT 0,
  p_ts timestamptz DEFAULT now()
) RETURNS void AS $$
BEGIN
  INSERT INTO public.chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, created_at, updated_at)
  VALUES (p_user_id, p_match_id, p_other_user_id, p_last_message_id, p_last_message_preview, p_last_message_at, GREATEST(p_unread_increment,0), COALESCE(p_ts, now()), COALESCE(p_ts, now()))
  ON CONFLICT (user_id, match_id) DO UPDATE
  SET
    other_user_id = EXCLUDED.other_user_id,
    last_message_id = COALESCE(EXCLUDED.last_message_id, chats.last_message_id),
    last_message_preview = COALESCE(EXCLUDED.last_message_preview, chats.last_message_preview),
    last_message_at = GREATEST(COALESCE(chats.last_message_at, EXCLUDED.last_message_at), COALESCE(EXCLUDED.last_message_at, chats.last_message_at)),
    unread_count = CASE
      -- If p_unread_increment > 0, increment unread count (for recipient)
      WHEN p_unread_increment > 0 THEN chats.unread_count + p_unread_increment
      -- If p_unread_increment = 0, set to 0 (for sender - they shouldn't have unread for their own message)
      ELSE 0
    END,
    updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql;

-- Fix existing bad data: Set unread_count to 0 for users who are the sender of the last message
-- This fixes cases where senders incorrectly have unread_count > 0
UPDATE public.chats c
SET unread_count = 0, updated_at = now()
WHERE c.unread_count > 0
AND EXISTS (
  SELECT 1 FROM public.chat_messages cm
  WHERE cm.match_id = c.match_id
  AND cm.id = c.last_message_id
  AND cm.sender_id = c.user_id
);