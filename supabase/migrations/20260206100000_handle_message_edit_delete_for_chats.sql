-- Migration: Handle message edits and deletes for the chats table
-- Purpose: Update the chats table when messages are edited or deleted

-- 1) Trigger function to handle UPDATE on chat_messages
-- When a message is edited, update the chats table if it's the latest message for that match
CREATE OR REPLACE FUNCTION public.handle_chat_message_update_for_chats() RETURNS trigger AS $$
DECLARE
  m_record RECORD;
  sender uuid;
  other uuid;
  latest_msg RECORD;
  preview text;
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    -- Only process if the content was actually changed (using current schema columns)
    IF (OLD.content_original_encrypted IS DISTINCT FROM NEW.content_original_encrypted
        OR OLD.encryption_scheme IS DISTINCT FROM NEW.encryption_scheme) THEN
      -- Resolve participants
      SELECT user1_id, user2_id INTO m_record FROM public.matches WHERE id = NEW.match_id;
      IF NOT FOUND THEN
        RETURN NEW;
      END IF;

      sender := NEW.sender_id;
      IF m_record.user1_id = sender THEN
        other := m_record.user2_id;
      ELSE
        other := m_record.user1_id;
      END IF;

      -- Check if this message is the latest for the match
      SELECT id, content_original_encrypted, created_at INTO latest_msg
      FROM public.chat_messages
      WHERE match_id = NEW.match_id
      ORDER BY created_at DESC
      LIMIT 1;

      -- If this is the latest message, update the chats table
      IF latest_msg.id = NEW.id THEN
        -- For encrypted messages, use placeholder
        IF NEW.encryption_scheme = 'v1' THEN
          preview := '[Encrypted message]';
        ELSE
          preview := '[Encrypted message]';
        END IF;
        
        -- Update both users' chat entries
        UPDATE public.chats 
        SET last_message_preview = preview, updated_at = now()
        WHERE match_id = NEW.match_id AND user_id IN (sender, other);
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach UPDATE trigger
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_chat_message_update_for_chats') THEN
      CREATE TRIGGER trg_handle_chat_message_update_for_chats
      AFTER UPDATE ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_update_for_chats();
    END IF;
  END IF;
END$$;

-- 2) Trigger function to handle DELETE on chat_messages
-- When a message is deleted, update the chats table to point to the new latest message
-- and decrement unread_count if the deleted message was unread
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

    -- Update the chats table for both participants
    IF latest_msg.id IS NOT NULL THEN
      -- Generate preview based on encryption scheme
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

-- Attach DELETE trigger
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_chat_message_delete_for_chats') THEN
      CREATE TRIGGER trg_handle_chat_message_delete_for_chats
      AFTER DELETE ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_delete_for_chats();
    END IF;
  END IF;
END$$;
