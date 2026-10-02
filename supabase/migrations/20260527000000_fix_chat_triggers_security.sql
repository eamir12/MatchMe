-- Migration: Fix chat triggers to use SECURITY DEFINER
-- Purpose: Allow triggers to update chats table for both sender and recipient regardless of RLS

BEGIN;

-- 1) Fix upsert_chat_row to be SECURITY DEFINER
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
    unread_count = CASE WHEN chats.unread_count = 0 THEN 1 ELSE chats.unread_count END,
    updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 2) Fix handle_chat_message_for_chats to be SECURITY DEFINER
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

  -- Upsert for sender with unread increment 0
  PERFORM public.upsert_chat_row(sender, NEW.match_id, other, NEW.id, preview, COALESCE(NEW.created_at, now()), 0, COALESCE(NEW.created_at, now()));

  -- Upsert for recipient with unread increment 1
  PERFORM public.upsert_chat_row(other, NEW.match_id, sender, NEW.id, preview, COALESCE(NEW.created_at, now()), 1, COALESCE(NEW.created_at, now()));

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3) Fix handle_message_read_for_chats to be SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.handle_message_read_for_chats() RETURNS trigger AS $$
DECLARE
  matchid uuid;
  reader uuid;
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF (OLD.read_at IS NULL AND NEW.read_at IS NOT NULL) THEN
      matchid := NEW.match_id;
      -- Try to use auth.uid() as the reader (who marked messages read). If not available, derive from match participants.
      reader := auth.uid();
      IF reader IS NULL THEN
        SELECT CASE WHEN m.user1_id = NEW.sender_id THEN m.user2_id ELSE m.user1_id END INTO reader
        FROM public.matches m WHERE m.id = NEW.match_id;
      END IF;
      UPDATE public.chats SET unread_count = 0, updated_at = now() WHERE user_id = reader AND match_id = matchid;
    END IF;
  END IF; 
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMIT;
