-- Migration: add per-chat per-user translation flags to `chats` table
-- Purpose: record whether translation is enabled for a chat (per-user row) and which language

BEGIN;

ALTER TABLE IF EXISTS public.chats ADD COLUMN IF NOT EXISTS translation_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE IF EXISTS public.chats ADD COLUMN IF NOT EXISTS translation_language text;

-- Update get_user_chats RPC to return the new fields
-- Drop old signature (if present) so we can change the RETURN row shape safely.
-- Note: PostgreSQL does not allow changing the OUT-parameter row type in-place.
DROP FUNCTION IF EXISTS public.get_user_chats(uuid, int);

CREATE FUNCTION public.get_user_chats(p_user_id uuid, p_limit int DEFAULT 5)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_id uuid,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  updated_at timestamptz,
  translation_enabled boolean,
  translation_language text
) AS $$
  SELECT c.match_id,
         c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         u.photos::text[] as other_photos,
         c.last_message_id,
         c.last_message_preview,
         c.last_message_at,
         c.unread_count,
         c.updated_at,
         c.translation_enabled,
         c.translation_language
  FROM public.chats c
  LEFT JOIN public.users u ON u.id = c.other_user_id
  WHERE c.user_id = p_user_id
  ORDER BY COALESCE(c.last_message_at, c.updated_at) DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION public.get_user_chats(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_chats(uuid, int) TO anon;

COMMIT;
