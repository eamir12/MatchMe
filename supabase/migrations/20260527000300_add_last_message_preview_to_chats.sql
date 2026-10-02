-- Migration: Fix chats schema and triggers
-- Purpose: Add missing last_message_preview column to chats table and update triggers.

BEGIN;

-- 1) Add last_message_preview column if it's missing
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='chats' AND column_name='last_message_preview') THEN
    ALTER TABLE public.chats ADD COLUMN last_message_preview text;
  END IF;
END$$;

-- 2) Update upsert_chat_row to include last_message_preview
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
      WHEN p_unread_increment > 0 THEN chats.unread_count + 1 
      ELSE chats.unread_count 
    END,
    updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3) Ensure handle_chat_message_for_chats is using correct columns
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

  -- Use content_original_encrypted for the preview (base64 for v1 encrypted messages)
  preview := substring(regexp_replace(coalesce(NEW.content_original_encrypted, ''), E'\n+', ' ', 'g') FROM 1 FOR 400);

  -- Upsert for sender (unread increment 0)
  PERFORM public.upsert_chat_row(sender, NEW.match_id, other, NEW.id, preview, COALESCE(NEW.created_at, now()), 0, COALESCE(NEW.created_at, now()));

  -- Upsert for recipient (unread increment 1)
  PERFORM public.upsert_chat_row(other, NEW.match_id, sender, NEW.id, preview, COALESCE(NEW.created_at, now()), 1, COALESCE(NEW.created_at, now()));

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMIT;
