-- Fix the critical unread count bug in the chats table
-- The current logic only sets unread_count to 1 if it's 0, but never increments beyond 1

-- Current buggy logic in upsert_chat_row function:
-- unread_count = CASE WHEN chats.unread_count = 0 THEN 1 ELSE chats.unread_count END

-- This means:
-- - If unread_count = 0 → becomes 1 (correct for first message)
-- - If unread_count = 1 → stays 1 (WRONG! should become 2 for second message)
-- - If unread_count = 2 → stays 2 (WRONG! should become 3 for third message)

-- Fix: Change to proper increment logic
UPDATE public.chats
SET unread_count = (
    SELECT COUNT(*)
    FROM public.chat_messages cm
    WHERE cm.match_id = chats.match_id
        AND cm.sender_id != chats.user_id
        AND cm.read_at IS NULL
);

-- Also fix the upsert_chat_row function to use proper increment logic
-- Current: unread_count = CASE WHEN chats.unread_count = 0 THEN 1 ELSE chats.unread_count END
-- Fixed: unread_count = chats.unread_count + p_unread_increment

-- Create the corrected function
CREATE OR REPLACE FUNCTION public.upsert_chat_row(
  p_user_id uuid,
  p_match_id uuid,
  p_other_user_id uuid,
  p_last_message_id uuid DEFAULT NULL,
  p_last_message_preview text DEFAULT '',
  p_last_message_at timestamptz DEFAULT now(),
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
    -- FIX: Use proper increment instead of broken CASE logic
    unread_count = chats.unread_count + EXCLUDED.unread_count,
    updated_at = GREATEST(chats.updated_at, EXCLUDED.updated_at);
END;
$$ LANGUAGE plpgsql;

-- Verify the fix by checking current unread counts
SELECT
    c.user_id,
    c.match_id,
    c.unread_count as stored_count,
    COUNT(cm.id) as actual_unread_count,
    CASE WHEN c.unread_count = COUNT(cm.id) THEN 'OK' ELSE 'MISMATCH' END as status
FROM public.chats c
LEFT JOIN public.chat_messages cm ON cm.match_id = c.match_id
    AND cm.sender_id != c.user_id
    AND cm.read_at IS NULL
GROUP BY c.user_id, c.match_id, c.unread_count
ORDER BY c.user_id, c.match_id;


