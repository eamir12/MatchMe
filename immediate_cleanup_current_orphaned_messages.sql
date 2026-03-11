-- IMMEDIATE CLEANUP: Delete chat messages that are no longer referenced by any chats
-- This will clean up messages for chats that have been deleted but messages remain

-- First, let's see what we're about to delete
SELECT
    cm.match_id,
    COUNT(cm.id) as message_count,
    MAX(cm.created_at) as latest_message
FROM public.chat_messages cm
LEFT JOIN public.chats c ON c.match_id = cm.match_id
WHERE c.match_id IS NULL  -- Messages where no chat entries exist
GROUP BY cm.match_id
ORDER BY latest_message DESC;

-- Now delete the orphaned messages
DELETE FROM public.chat_messages
WHERE match_id NOT IN (
    SELECT DISTINCT match_id FROM public.chats
);

-- Show cleanup summary
SELECT 'Cleanup completed. Deleted orphaned messages for matches no longer in any user\'s chat list.' as status;


