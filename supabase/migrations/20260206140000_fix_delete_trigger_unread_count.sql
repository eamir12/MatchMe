-- Migration: Fix message delete trigger to update unread_count
-- Purpose: When a message is deleted, decrement the unread_count in the chats table
--          for the recipient if the message was unread (read_at IS NULL)

BEGIN;

-- Drop the old trigger
DROP TRIGGER IF EXISTS trg_handle_chat_message_delete_for_chats ON public.chat_messages;

-- Update the trigger function to handle unread_count
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
    SELECT id, content_original, created_at INTO latest_msg
    FROM public.chat_messages
    WHERE match_id = OLD.match_id
    ORDER BY created_at DESC
    LIMIT 1;

    -- Update the chats table for both participants
    IF latest_msg.id IS NOT NULL THEN
      -- New message exists, update chats to point to it
      preview := substring(regexp_replace(coalesce(latest_msg.content_original, ''), E'\n+', ' ', 'g') FROM 1 FOR 400);
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
      -- No messages left, clear the chat preview and reset unread count
      UPDATE public.chats 
      SET last_message_id = NULL, 
          last_message_preview = '', 
          last_message_at = NULL,
          unread_count = 0,
          updated_at = now()
      WHERE match_id = OLD.match_id AND user_id IN (sender, other);
    END IF;
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger
CREATE TRIGGER trg_handle_chat_message_delete_for_chats
AFTER DELETE ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_delete_for_chats();

COMMIT;
