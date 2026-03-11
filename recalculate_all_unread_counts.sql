-- Recalculate all unread counts in the chats table to fix any inconsistencies
-- This should be run periodically or when badge issues are detected

-- Update all unread counts to match the actual count of unread messages
UPDATE public.chats
SET unread_count = COALESCE((
    SELECT COUNT(*)
    FROM public.chat_messages cm
    WHERE cm.match_id = chats.match_id
        AND cm.sender_id != chats.user_id
        AND cm.read_at IS NULL
), 0);

-- Show summary of the fix
SELECT
    'Total chats updated' as description,
    COUNT(*) as count
FROM public.chats
WHERE unread_count > 0;

-- Show any chats that still have incorrect unread counts (for debugging)
SELECT
    c.user_id,
    c.match_id,
    c.unread_count as stored_count,
    COUNT(cm.id) as actual_count,
    CASE WHEN c.unread_count != COUNT(cm.id) THEN 'MISMATCH' ELSE 'OK' END as status
FROM public.chats c
LEFT JOIN public.chat_messages cm ON cm.match_id = c.match_id
    AND cm.sender_id != c.user_id
    AND cm.read_at IS NULL
GROUP BY c.user_id, c.match_id, c.unread_count
HAVING c.unread_count != COUNT(cm.id)
ORDER BY c.user_id;


