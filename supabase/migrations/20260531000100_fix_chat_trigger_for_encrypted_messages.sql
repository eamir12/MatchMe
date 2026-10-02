-- Migration: Fix chat trigger to handle encrypted messages properly
-- Purpose: Ensure chats table rows are created even when messages are encrypted (v1 scheme)

BEGIN;

CREATE OR REPLACE FUNCTION public.handle_chat_message_for_chats() RETURNS trigger AS $$
DECLARE
  m_record RECORD;
  sender uuid;
  other uuid;
  preview text;
BEGIN
  -- Resolve participants for the match
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

  -- Generate preview based on encryption scheme
  IF NEW.encryption_scheme = 'v1' THEN
    -- For encrypted messages, use a placeholder preview
    -- The client will decrypt and display the actual content
    preview := '[Encrypted message]';
  ELSE
    -- Fallback for unexpected encryption schemes
    preview := '[Encrypted message]';
  END IF;

  -- Upsert for sender (unread increment 0)
  PERFORM public.upsert_chat_row(sender, NEW.match_id, other, NEW.id, preview, COALESCE(NEW.created_at, now()), 0, COALESCE(NEW.created_at, now()));

  -- Upsert for recipient (unread increment 1)
  PERFORM public.upsert_chat_row(other, NEW.match_id, sender, NEW.id, preview, COALESCE(NEW.created_at, now()), 1, COALESCE(NEW.created_at, now()));

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMIT;
