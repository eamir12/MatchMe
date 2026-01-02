-- Migration: fix message read trigger functions
-- Purpose: avoid referencing non-existent recipient_id column; use auth.uid() with fallback to match participants

BEGIN;

-- Drop dependent triggers first to allow replacing functions
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read_for_chats') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_handle_message_read_for_chats ON public.chat_messages';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_handle_message_read ON public.chat_messages';
  END IF;
END$$;

-- Replace handle_message_read_for_chats
DROP FUNCTION IF EXISTS public.handle_message_read_for_chats();
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
$$ LANGUAGE plpgsql;

-- Replace handle_message_read (for user_recent_chats)
DROP FUNCTION IF EXISTS public.handle_message_read();
CREATE OR REPLACE FUNCTION public.handle_message_read() RETURNS trigger AS $$
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
      UPDATE public.user_recent_chats SET unread_count = 0 WHERE user_id = reader AND match_id = matchid;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate triggers if chat_messages table and read_at column exist
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='chat_messages' AND column_name='read_at') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read_for_chats') THEN
      CREATE TRIGGER trg_handle_message_read_for_chats
      AFTER UPDATE ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_message_read_for_chats();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read') THEN
      CREATE TRIGGER trg_handle_message_read
      AFTER UPDATE ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_message_read();
    END IF;
  END IF;
END$$;

COMMIT;
