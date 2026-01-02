-- Migration: remove legacy user_recent_chats and consolidate to public.chats
-- Purpose: drop legacy table, replace RPCs and remove functions/triggers that depend on user_recent_chats

BEGIN;

-- 1) Drop triggers and functions that reference user_recent_chats
DO $$
BEGIN
  -- Drop trigger if exists
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_message_read') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_handle_message_read ON public.chat_messages';
  END IF;
  -- Drop the function used by that trigger
  DROP FUNCTION IF EXISTS public.handle_message_read();
  DROP FUNCTION IF EXISTS public.upsert_user_recent_chat(uuid, uuid, uuid, uuid, text, timestamptz, integer, timestamptz);
EXCEPTION WHEN others THEN
  -- Ignore, we want this migration to be idempotent
  RAISE NOTICE 'Ignoring errors while dropping legacy functions/triggers: %', SQLERRM;
END$$;

-- 2) Replace get_user_recent_chats RPC to select from public.chats for backward compatibility
DROP FUNCTION IF EXISTS public.get_user_recent_chats(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_chats(p_user_id uuid, p_limit int DEFAULT 20)
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

GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid, int) TO anon;

-- 3) Drop legacy table if exists
DROP TABLE IF EXISTS public.user_recent_chats CASCADE;

COMMIT;
