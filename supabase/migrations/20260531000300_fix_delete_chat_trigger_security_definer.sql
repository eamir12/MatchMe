-- Migration: Fix delete chat trigger function to use SECURITY DEFINER
-- Purpose: Allow the trigger to delete chat rows for both participants
-- when the last message in a match is deleted. The function must run with
-- SECURITY DEFINER (like all other trigger functions on chat_messages) to
-- bypass RLS, since there is no DELETE policy for authenticated users on
-- the chats table (and it wouldn't cover the other participant anyway).

BEGIN;

DROP FUNCTION IF EXISTS public.handle_chat_message_delete_for_chats() CASCADE;

CREATE OR REPLACE FUNCTION public.handle_chat_message_delete_for_chats() RETURNS trigger AS $$
DECLARE
  m_record RECORD;
  sender uuid;
  other uuid;
  latest_msg RECORD;
  preview text;
  was_unread boolean;
BEGIN
  IF (TG_OP = 'DELETE') THEN
    -- Resolve participants
    SELECT user1_id, user2_id INTO m_record FROM public.matches WHERE id = OLD.match_id;
    IF NOT FOUND THEN
      RETURN OLD;
    END IF;

    sender := OLD.sender_id;
    IF m_record.user1_id = sender THEN
      other := m_record.user2_id;
    ELSE
      other := m_record.user1_id;
    END IF;

    -- Check if the deleted message was unread
    was_unread := (OLD.read_at IS NULL);

    -- Find the new latest message for this match after deletion
    SELECT id, content_original_encrypted, encryption_scheme, created_at INTO latest_msg
    FROM public.chat_messages
    WHERE match_id = OLD.match_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF latest_msg.id IS NOT NULL THEN
      -- New message exists, update chats to point to it
      IF latest_msg.encryption_scheme = 'v1' THEN
        preview := '[Encrypted message]';
      ELSE
        preview := substring(regexp_replace(coalesce(latest_msg.content_original_encrypted, ''), E'\n+', ' ', 'g') FROM 1 FOR 400);
      END IF;
      UPDATE public.chats 
      SET last_message_id = latest_msg.id, 
          last_message_preview = preview, 
          last_message_at = latest_msg.created_at,
          unread_count = CASE 
            WHEN user_id = other AND was_unread AND unread_count > 0 THEN unread_count - 1
            ELSE unread_count 
          END,
          updated_at = now()
      WHERE match_id = OLD.match_id AND user_id IN (sender, other);
    ELSE
      -- No messages left — delete the chats rows entirely so the chat
      -- disappears in realtime from Recent Chats / Chats screen.
      DELETE FROM public.chats
      WHERE match_id = OLD.match_id AND user_id IN (sender, other);
    END IF;
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trg_handle_chat_message_delete_for_chats
AFTER DELETE ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_delete_for_chats();

-- Clean up existing orphaned chat rows that were left behind by the buggy
-- SECURITY INVOKER trigger. These are rows in public.chats that have no
-- corresponding messages in public.chat_messages.
DELETE FROM public.chats c
WHERE NOT EXISTS (
    SELECT 1 FROM public.chat_messages cm
    WHERE cm.match_id = c.match_id
);

COMMIT;
