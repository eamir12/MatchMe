-- Migration: create per-user `chats` table and supporting RPCs/triggers
-- Purpose: Maintain a complete list of a user's chats (one row per user+match)

BEGIN;

-- 1) Table
CREATE TABLE IF NOT EXISTS public.chats (
  user_id uuid NOT NULL,
  match_id uuid NOT NULL,
  other_user_id uuid NOT NULL,
  last_message_id uuid,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, match_id)
);

CREATE INDEX IF NOT EXISTS idx_chats_user_last_message ON public.chats (user_id, last_message_at DESC NULLS LAST);

-- 2) Upsert function for chats
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
    unread_count = GREATEST(chats.unread_count + EXCLUDED.unread_count, 0),
    updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql;

-- 3) Trigger function: on new message, upsert chat rows for sender and recipient
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
$$ LANGUAGE plpgsql;

-- Attach trigger if chat_messages table exists and trigger not already created
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_chat_message_for_chats') THEN
      CREATE TRIGGER trg_handle_chat_message_for_chats
      AFTER INSERT ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_for_chats();
    END IF;
  END IF;
END$$;

-- 4) Trigger function: when a message's read_at becomes non-null, clear unread for that user for the match
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

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='chat_messages' AND column_name='read_at') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read_for_chats') THEN
      CREATE TRIGGER trg_handle_message_read_for_chats
      AFTER UPDATE ON public.chat_messages
      FOR EACH ROW EXECUTE FUNCTION public.handle_message_read_for_chats();
    END IF;
  END IF;
END$$;

-- 5) RPC to fetch top N chats for a user, ordered by last_message_at desc (limit default 5)
CREATE OR REPLACE FUNCTION public.get_user_chats(p_user_id uuid, p_limit int DEFAULT 5)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_id uuid,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  updated_at timestamptz
) AS $$
  SELECT c.match_id,
         c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         u.photos::text[] as other_photos,
         c.last_message_id,
         c.last_message_preview,
         c.last_message_at,
         c.unread_count,
         c.updated_at
  FROM public.chats c
  LEFT JOIN public.users u ON u.id = c.other_user_id
  WHERE c.user_id = p_user_id
  ORDER BY COALESCE(c.last_message_at, c.updated_at) DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- 6) Backfill: populate chats from existing matches & last messages
WITH last_msg AS (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
)
INSERT INTO public.chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, created_at, updated_at)
SELECT m.user1_id, lm.match_id, m.user2_id, lm.last_message_id, substring(regexp_replace(coalesce(lm.content_original, ''), E'\n+', ' ', 'g') FROM 1 FOR 400), lm.created_at,
  (SELECT count(1) FROM public.chat_messages c WHERE c.match_id = lm.match_id AND c.sender_id <> m.user1_id AND c.read_at IS NULL), lm.created_at, lm.created_at
FROM public.matches m
LEFT JOIN (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
) lm ON lm.match_id = m.id
WHERE lm.match_id IS NOT NULL
ON CONFLICT (user_id, match_id) DO UPDATE SET
  last_message_id = COALESCE(EXCLUDED.last_message_id, chats.last_message_id),
  last_message_preview = COALESCE(EXCLUDED.last_message_preview, chats.last_message_preview),
  last_message_at = GREATEST(COALESCE(chats.last_message_at, EXCLUDED.last_message_at), COALESCE(EXCLUDED.last_message_at, chats.last_message_at)),
  unread_count = GREATEST(chats.unread_count, EXCLUDED.unread_count),
  updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);

WITH last_msg AS (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
)
INSERT INTO public.chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, created_at, updated_at)
SELECT m.user2_id, lm.match_id, m.user1_id, lm.last_message_id, substring(regexp_replace(coalesce(lm.content_original, ''), E'\n+', ' ', 'g') FROM 1 FOR 400), lm.created_at,
  (SELECT count(1) FROM public.chat_messages c WHERE c.match_id = lm.match_id AND c.sender_id <> m.user2_id AND c.read_at IS NULL), lm.created_at, lm.created_at
FROM public.matches m
LEFT JOIN (
  SELECT DISTINCT ON (match_id) match_id, id as last_message_id, sender_id, content_original, created_at
  FROM public.chat_messages
  ORDER BY match_id, created_at DESC
) lm ON lm.match_id = m.id
WHERE lm.match_id IS NOT NULL
ON CONFLICT (user_id, match_id) DO UPDATE SET
  last_message_id = COALESCE(EXCLUDED.last_message_id, chats.last_message_id),
  last_message_preview = COALESCE(EXCLUDED.last_message_preview, chats.last_message_preview),
  last_message_at = GREATEST(COALESCE(chats.last_message_at, EXCLUDED.last_message_at), COALESCE(EXCLUDED.last_message_at, chats.last_message_at)),
  unread_count = GREATEST(chats.unread_count, EXCLUDED.unread_count),
  updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);

COMMIT;
