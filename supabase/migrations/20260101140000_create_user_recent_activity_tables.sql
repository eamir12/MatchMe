-- Migration: create user_recent_matches and user_recent_chats tables
-- Add upsert functions, triggers, and a backfill step

BEGIN;

-- 1) Tables
CREATE TABLE IF NOT EXISTS public.user_recent_matches (
  user_id uuid NOT NULL,
  match_id uuid NOT NULL,
  other_user_id uuid NOT NULL,
  match_type text,
  matched_intent text,
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, match_id)
);

CREATE INDEX IF NOT EXISTS idx_user_recent_matches_user_last_activity ON public.user_recent_matches (user_id, last_activity_at DESC);

CREATE TABLE IF NOT EXISTS public.user_recent_chats (
  user_id uuid NOT NULL,
  match_id uuid NOT NULL,
  other_user_id uuid NOT NULL,
  last_message_id uuid,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer DEFAULT 0,
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, match_id)
);

CREATE INDEX IF NOT EXISTS idx_user_recent_chats_user_last_activity ON public.user_recent_chats (user_id, last_activity_at DESC);

-- 2) Upsert function for matches
CREATE OR REPLACE FUNCTION public.upsert_user_recent_match(
  p_user_id uuid,
  p_match_id uuid,
  p_other_user_id uuid,
  p_match_type text,
  p_matched_intent text,
  p_activity timestamptz DEFAULT now(),
  p_created_at timestamptz DEFAULT now()
) RETURNS void AS $$
BEGIN
  INSERT INTO public.user_recent_matches (user_id, match_id, other_user_id, match_type, matched_intent, last_activity_at, created_at)
  VALUES (p_user_id, p_match_id, p_other_user_id, p_match_type, p_matched_intent, p_activity, p_created_at)
  ON CONFLICT (user_id, match_id) DO UPDATE
  SET
    other_user_id = EXCLUDED.other_user_id,
    match_type = COALESCE(EXCLUDED.match_type, user_recent_matches.match_type),
    matched_intent = COALESCE(EXCLUDED.matched_intent, user_recent_matches.matched_intent),
    last_activity_at = GREATEST(user_recent_matches.last_activity_at, EXCLUDED.last_activity_at),
    created_at = LEAST(user_recent_matches.created_at, EXCLUDED.created_at);
END;
$$ LANGUAGE plpgsql;

-- 3) Upsert function for chats
CREATE OR REPLACE FUNCTION public.upsert_user_recent_chat(
  p_user_id uuid,
  p_match_id uuid,
  p_other_user_id uuid,
  p_last_message_id uuid,
  p_last_message_preview text,
  p_last_message_at timestamptz,
  p_unread_increment integer DEFAULT 0,
  p_activity timestamptz DEFAULT now()
) RETURNS void AS $$
BEGIN
  INSERT INTO public.user_recent_chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, last_activity_at)
  VALUES (p_user_id, p_match_id, p_other_user_id, p_last_message_id, p_last_message_preview, p_last_message_at, GREATEST(p_unread_increment,0), p_activity)
  ON CONFLICT (user_id, match_id) DO UPDATE
  SET
    other_user_id = EXCLUDED.other_user_id,
    last_message_id = COALESCE(EXCLUDED.last_message_id, user_recent_chats.last_message_id),
    last_message_preview = COALESCE(EXCLUDED.last_message_preview, user_recent_chats.last_message_preview),
    last_message_at = GREATEST(COALESCE(user_recent_chats.last_message_at, EXCLUDED.last_message_at), COALESCE(EXCLUDED.last_message_at, user_recent_chats.last_message_at)),
    unread_count = GREATEST(user_recent_chats.unread_count + EXCLUDED.unread_count, 0),
    last_activity_at = GREATEST(user_recent_chats.last_activity_at, EXCLUDED.last_activity_at);
END;
$$ LANGUAGE plpgsql;

-- 4) Trigger to update recent matches when a match is created
CREATE OR REPLACE FUNCTION public.handle_new_match() RETURNS trigger AS $$
BEGIN
  -- Upsert for both participants
  PERFORM public.upsert_user_recent_match(NEW.user1_id, NEW.id, NEW.user2_id, NEW.match_type, NEW.matched_intent, COALESCE(NEW.created_at, now()), COALESCE(NEW.created_at, now()));
  PERFORM public.upsert_user_recent_match(NEW.user2_id, NEW.id, NEW.user1_id, NEW.match_type, NEW.matched_intent, COALESCE(NEW.created_at, now()), COALESCE(NEW.created_at, now()));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to matches table if it exists
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='matches') THEN
    -- drop existing trigger if present
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_new_match') THEN
      CREATE TRIGGER trg_handle_new_match
      AFTER INSERT ON public.matches
      FOR EACH ROW EXECUTE FUNCTION public.handle_new_match();
    END IF;
  END IF;
END$$;

-- 5) Trigger to update recent chats on chat_messages inserts
CREATE OR REPLACE FUNCTION public.handle_chat_message() RETURNS trigger AS $$
DECLARE
  m_record RECORD;
  recipient uuid;
  sender uuid;
  preview text;
BEGIN
  -- Get match participants
  SELECT user1_id, user2_id INTO m_record FROM public.matches WHERE id = NEW.match_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  sender := NEW.sender_id;
  IF m_record.user1_id = sender THEN
    recipient := m_record.user2_id;
  ELSE
    recipient := m_record.user1_id;
  END IF;

  -- Short preview (strip newlines, limit 200 chars)
  preview := substring(regexp_replace(coalesce(NEW.content_original, ''), E'\n+', ' ', 'g') FROM 1 FOR 200);

  -- Upsert for sender (unread_increment 0)
  PERFORM public.upsert_user_recent_chat(sender, NEW.match_id, recipient, NEW.id, preview, COALESCE(NEW.created_at, now()), 0, COALESCE(NEW.created_at, now()));

  -- Upsert for recipient (increment unread count by 1)
  PERFORM public.upsert_user_recent_chat(recipient, NEW.match_id, sender, NEW.id, preview, COALESCE(NEW.created_at, now()), 1, COALESCE(NEW.created_at, now()));

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_chat_message') THEN
      CREATE TRIGGER trg_handle_chat_message
      AFTER INSERT ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message();
    END IF;
  END IF;
END$$;

-- 6) Trigger to reset unread count when messages are marked read (assumes chat_messages has 'read_at' timestamp and 'recipient_id')
CREATE OR REPLACE FUNCTION public.handle_message_read() RETURNS trigger AS $$
DECLARE
  affected RECORD;
  matchid uuid;
  reader uuid;
BEGIN
  -- If read_at changed from null to non-null
  IF (TG_OP = 'UPDATE') THEN
    IF (OLD.read_at IS NULL AND NEW.read_at IS NOT NULL) THEN
      matchid := NEW.match_id;
      -- Try to use auth.uid() as the reader (who marked messages read). If not available, derive from match participants.
      reader := auth.uid();
      IF reader IS NULL THEN
        SELECT CASE WHEN m.user1_id = NEW.sender_id THEN m.user2_id ELSE m.user1_id END INTO reader
        FROM public.matches m WHERE m.id = NEW.match_id;
      END IF;
      -- set unread_count to zero for reader for this match
      UPDATE public.user_recent_chats SET unread_count = 0 WHERE user_id = reader AND match_id = matchid;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='chat_messages' AND column_name='read_at') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read') THEN
      CREATE TRIGGER trg_handle_message_read
      AFTER UPDATE ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_message_read();
    END IF;
  END IF;
END$$;

-- 7) Backfill recent matches and chats (best-effort, idempotent)
-- Backfill recent matches from existing matches table
INSERT INTO public.user_recent_matches (user_id, match_id, other_user_id, match_type, matched_intent, last_activity_at, created_at)
SELECT m.user1_id, m.id, m.user2_id, m.match_type, m.matched_intent, COALESCE(max(coalesce(cm.created_at, m.created_at)), m.created_at), m.created_at
FROM public.matches m
LEFT JOIN public.chat_messages cm ON cm.match_id = m.id
GROUP BY m.user1_id, m.id, m.user2_id, m.match_type, m.matched_intent, m.created_at
ON CONFLICT (user_id, match_id) DO UPDATE SET
  other_user_id = EXCLUDED.other_user_id,
  match_type = EXCLUDED.match_type,
  matched_intent = EXCLUDED.matched_intent,
  last_activity_at = GREATEST(user_recent_matches.last_activity_at, EXCLUDED.last_activity_at),
  created_at = LEAST(user_recent_matches.created_at, EXCLUDED.created_at);

INSERT INTO public.user_recent_matches (user_id, match_id, other_user_id, match_type, matched_intent, last_activity_at, created_at)
SELECT m.user2_id, m.id, m.user1_id, m.match_type, m.matched_intent, COALESCE(max(coalesce(cm.created_at, m.created_at)), m.created_at), m.created_at
FROM public.matches m
LEFT JOIN public.chat_messages cm ON cm.match_id = m.id
GROUP BY m.user2_id, m.id, m.user1_id, m.match_type, m.matched_intent, m.created_at
ON CONFLICT (user_id, match_id) DO UPDATE SET
  other_user_id = EXCLUDED.other_user_id,
  match_type = EXCLUDED.match_type,
  matched_intent = EXCLUDED.matched_intent,
  last_activity_at = GREATEST(user_recent_matches.last_activity_at, EXCLUDED.last_activity_at),
  created_at = LEAST(user_recent_matches.created_at, EXCLUDED.created_at);

-- Backfill recent chats: last message per match becomes last_message for both participants
WITH last_msg AS (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
)
INSERT INTO public.user_recent_chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, last_activity_at)
SELECT m.user1_id, lm.match_id, m.user2_id, lm.last_message_id, substring(regexp_replace(coalesce(lm.content_original,''), E'\n+', ' ', 'g') FROM 1 FOR 200), lm.created_at, 
  (SELECT count(1) FROM public.chat_messages c WHERE c.match_id = lm.match_id AND c.sender_id <> m.user1_id AND c.read_at IS NULL), lm.created_at
FROM public.matches m
LEFT JOIN (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
) lm ON lm.match_id = m.id
WHERE lm.match_id IS NOT NULL
ON CONFLICT (user_id, match_id) DO UPDATE SET
  last_message_id = COALESCE(EXCLUDED.last_message_id, user_recent_chats.last_message_id),
  last_message_preview = COALESCE(EXCLUDED.last_message_preview, user_recent_chats.last_message_preview),
  last_message_at = GREATEST(COALESCE(user_recent_chats.last_message_at, EXCLUDED.last_message_at), COALESCE(EXCLUDED.last_message_at, user_recent_chats.last_message_at)),
  unread_count = GREATEST(user_recent_chats.unread_count, EXCLUDED.unread_count),
  last_activity_at = GREATEST(user_recent_chats.last_activity_at, EXCLUDED.last_activity_at);

WITH last_msg AS (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
)
INSERT INTO public.user_recent_chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, last_activity_at)
SELECT m.user2_id, lm.match_id, m.user1_id, lm.last_message_id, substring(regexp_replace(coalesce(lm.content_original,''), E'\n+', ' ', 'g') FROM 1 FOR 200), lm.created_at,
  (SELECT count(1) FROM public.chat_messages c WHERE c.match_id = lm.match_id AND c.sender_id <> m.user2_id AND c.read_at IS NULL), lm.created_at
FROM public.matches m
LEFT JOIN (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
) lm ON lm.match_id = m.id
WHERE lm.match_id IS NOT NULL
ON CONFLICT (user_id, match_id) DO UPDATE SET
  last_message_id = COALESCE(EXCLUDED.last_message_id, user_recent_chats.last_message_id),
  last_message_preview = COALESCE(EXCLUDED.last_message_preview, user_recent_chats.last_message_preview),
  last_message_at = GREATEST(COALESCE(user_recent_chats.last_message_at, EXCLUDED.last_message_at), COALESCE(EXCLUDED.last_message_at, user_recent_chats.last_message_at)),
  unread_count = GREATEST(user_recent_chats.unread_count, EXCLUDED.unread_count),
  last_activity_at = GREATEST(user_recent_chats.last_activity_at, EXCLUDED.last_activity_at);

COMMIT;
