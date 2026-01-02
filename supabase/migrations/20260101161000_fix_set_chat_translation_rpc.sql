-- Migration: fix set_chat_translation RPC implementation
-- Purpose: ensure other_user_id is derived from matches and avoid inserting NULL into not-null column

BEGIN;

DROP FUNCTION IF EXISTS public.set_chat_translation(uuid, uuid, boolean, text);
CREATE OR REPLACE FUNCTION public.set_chat_translation(
  p_user_id uuid,
  p_match_id uuid,
  p_enabled boolean,
  p_language text
) RETURNS void AS $$
DECLARE
  other uuid;
BEGIN
  -- Derive the other participant for this match
  SELECT CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END INTO other
  FROM public.matches m WHERE m.id = p_match_id;

  IF other IS NULL THEN
    RAISE EXCEPTION 'match % not found for user %', p_match_id, p_user_id;
  END IF;

  -- Ensure an upsert exists for this user+match
  INSERT INTO public.chats (user_id, match_id, other_user_id, last_message_id, last_message_preview, last_message_at, unread_count, created_at, updated_at, translation_enabled, translation_language)
  VALUES (p_user_id, p_match_id, other, NULL, NULL, NULL, 0, now(), now(), p_enabled, p_language)
  ON CONFLICT (user_id, match_id) DO UPDATE
  SET translation_enabled = COALESCE(EXCLUDED.translation_enabled, chats.translation_enabled),
      translation_language = EXCLUDED.translation_language,
      updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION public.set_chat_translation(uuid, uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_chat_translation(uuid, uuid, boolean, text) TO anon;

COMMIT;
