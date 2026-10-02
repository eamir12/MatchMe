-- Migration: Final fix for chat RLS and triggers
-- Purpose: 
-- 1. Remove ALL legacy triggers and functions related to user_recent_chats
-- 2. Ensure all active triggers use SECURITY DEFINER to bypass RLS for internal metadata
-- 3. Simplify and harden RLS policies for chat_messages

BEGIN;

-- 1) DROP LEGACY TRIGGERS on chat_messages
DROP TRIGGER IF EXISTS trg_handle_chat_message ON public.chat_messages;
DROP TRIGGER IF EXISTS trg_handle_message_read ON public.chat_messages;
DROP TRIGGER IF EXISTS trg_handle_chat_message_for_chats ON public.chat_messages;
DROP TRIGGER IF EXISTS trg_handle_message_read_for_chats ON public.chat_messages;

-- 2) DROP LEGACY FUNCTIONS
DROP FUNCTION IF EXISTS public.handle_chat_message();
DROP FUNCTION IF EXISTS public.handle_message_read();
DROP FUNCTION IF EXISTS public.upsert_user_recent_chat(uuid, uuid, uuid, uuid, text, timestamptz, integer, timestamptz);

-- 3) ENSURE CORE FUNCTIONS ARE SECURITY DEFINER
-- This allows triggers to update the 'chats' table for both participants regardless of RLS
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
      WHEN chats.user_id = EXCLUDED.user_id THEN 
        CASE WHEN EXCLUDED.unread_count > 0 THEN chats.unread_count + 1 ELSE chats.unread_count END
      ELSE chats.unread_count 
    END,
    updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

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

  preview := substring(regexp_replace(coalesce(NEW.content_original, ''), E'\n+', ' ', 'g') FROM 1 FOR 400);

  -- Upsert for sender (unread increment 0)
  PERFORM public.upsert_chat_row(sender, NEW.match_id, other, NEW.id, preview, COALESCE(NEW.created_at, now()), 0, COALESCE(NEW.created_at, now()));

  -- Upsert for recipient (unread increment 1)
  PERFORM public.upsert_chat_row(other, NEW.match_id, sender, NEW.id, preview, COALESCE(NEW.created_at, now()), 1, COALESCE(NEW.created_at, now()));

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION public.handle_message_read_for_chats() RETURNS trigger AS $$
DECLARE
  matchid uuid;
  reader uuid;
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF (OLD.read_at IS NULL AND NEW.read_at IS NOT NULL) THEN
      matchid := NEW.match_id;
      -- Derive reader from who is marking the message as read (the recipient of the original message)
      -- NEW.sender_id is who sent it, so the reader is the OTHER person in the match.
      SELECT CASE WHEN m.user1_id = NEW.sender_id THEN m.user2_id ELSE m.user1_id END INTO reader
      FROM public.matches m WHERE m.id = NEW.match_id;
      
      IF reader IS NOT NULL THEN
        UPDATE public.chats SET unread_count = 0, updated_at = now() WHERE user_id = reader AND match_id = matchid;
      END IF;
    END IF;
  END IF; 
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 4) RECREATE TRIGGERS
CREATE TRIGGER trg_handle_chat_message_for_chats
AFTER INSERT ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_for_chats();

CREATE TRIGGER trg_handle_message_read_for_chats
AFTER UPDATE ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.handle_message_read_for_chats();

-- 5) HARDEN chat_messages RLS
DROP POLICY IF EXISTS "Users can insert messages for their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can view messages for their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can update messages in their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can delete their own messages" ON chat_messages;

-- Ensure RLS is enabled
ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

-- Policy for INSERT: Only authenticated users can insert their own messages into matches they belong to
CREATE POLICY "chat_messages_insert_policy"
ON chat_messages
FOR INSERT
TO authenticated
WITH CHECK (
    auth.uid() = sender_id
    AND EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
);

-- Policy for SELECT: Users can only see messages in matches they are part of
CREATE POLICY "chat_messages_select_policy"
ON chat_messages
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
);

-- Policy for UPDATE: Users can update messages in their matches (e.g. for translation metadata)
CREATE POLICY "chat_messages_update_policy"
ON chat_messages
FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
);

-- Policy for DELETE: Users can delete their own messages
CREATE POLICY "chat_messages_delete_policy"
ON chat_messages
FOR DELETE
TO authenticated
USING (auth.uid() = sender_id);

-- 6) GRANT PERMISSIONS
GRANT ALL ON chat_messages TO authenticated;
GRANT SELECT ON chat_messages TO anon; -- Allow anon to select (RLS will still filter out everything)

COMMIT;
