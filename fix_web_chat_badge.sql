-- Fix incorrect unread count for web user
-- User ID: 35fe114e-eae5-49d6-9eba-8459617e7b82
-- Match ID: 5e9ce4ec-7a8e-4536-be49-ac3e68d27092

-- First, let's check the current state
SELECT
    c.user_id,
    c.match_id,
    c.unread_count as current_unread_count,
    COUNT(cm.id) as actual_unread_messages
FROM public.chats c
LEFT JOIN public.chat_messages cm ON cm.match_id = c.match_id
    AND cm.sender_id != c.user_id
    AND cm.read_at IS NULL
WHERE c.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND c.match_id = '5e9ce4ec-7a8e-4536-be49-ac3e68d27092'
GROUP BY c.user_id, c.match_id, c.unread_count;

-- Fix the unread count to match actual unread messages
UPDATE public.chats
SET unread_count = (
    SELECT COUNT(*)
    FROM public.chat_messages cm
    WHERE cm.match_id = chats.match_id
        AND cm.sender_id != chats.user_id
        AND cm.read_at IS NULL
)
WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND match_id = '5e9ce4ec-7a8e-4536-be49-ac3e68d27092';

-- Verify the fix
SELECT
    c.user_id,
    c.match_id,
    c.unread_count as fixed_unread_count,
    COUNT(cm.id) as actual_unread_messages
FROM public.chats c
LEFT JOIN public.chat_messages cm ON cm.match_id = c.match_id
    AND cm.sender_id != c.user_id
    AND cm.read_at IS NULL
WHERE c.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND c.match_id = '5e9ce4ec-7a8e-4536-be49-ac3e68d27092'
GROUP BY c.user_id, c.match_id, c.unread_count;


