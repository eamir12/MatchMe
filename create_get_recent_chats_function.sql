-- Create the get_recent_chats function
-- This function returns chat data only for matches that have at least one message
DROP FUNCTION IF EXISTS get_recent_chats(UUID);
CREATE OR REPLACE FUNCTION get_recent_chats(p_user_id UUID)
RETURNS TABLE (
    match_id UUID,
    other_user_id UUID,
    other_user_name TEXT,
    last_message_content TEXT,
    last_message_id UUID,
    last_message_at TIMESTAMP WITH TIME ZONE,
    unread_count INTEGER,
    match_created_at TIMESTAMP WITH TIME ZONE,
    event_id UUID,
    event_name TEXT,
    event_link TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    RETURN QUERY
    SELECT DISTINCT
        m.id AS match_id,
        CASE
            WHEN m.user1_id = p_user_id THEN m.user2_id
            ELSE m.user1_id
        END AS other_user_id,
        -- Use DB function to mask names so last names are never returned
        public.mask_full_name(up.profile_data->>'fullName') AS other_user_name,
        COALESCE(cm.content_translated, cm.content_original) AS last_message_content,
        cm.id AS last_message_id,
        cm.created_at AS last_message_at,
        -- Count messages from the other user that are unread (read_at IS NULL)
        (SELECT COUNT(*)::integer
         FROM chat_messages cm_unread
         WHERE cm_unread.match_id = m.id
         AND cm_unread.sender_id != p_user_id
         AND cm_unread.read_at IS NULL) AS unread_count,
        m.created_at AS match_created_at,
        m.event_id,
        e.event_name,
        e.event_link
    FROM matches m
    -- Join with user_profiles to get the other user's name
    LEFT JOIN user_profiles up ON up.user_id = CASE
        WHEN m.user1_id = p_user_id THEN m.user2_id
        ELSE m.user1_id
    END
    -- Join with events to get event details
    LEFT JOIN events e ON e.id = m.event_id
    -- Join with chat_messages to get the last message
    INNER JOIN chat_messages cm ON cm.match_id = m.id
    -- Ensure we only include matches that have messages
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
    -- Get only the most recent message per match
    AND cm.id = (
        SELECT cm_sub.id
        FROM chat_messages cm_sub
        WHERE cm_sub.match_id = m.id
        ORDER BY cm_sub.created_at DESC
        LIMIT 1
    )
    ORDER BY cm.created_at DESC;

    RETURN;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION get_recent_chats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_recent_chats(UUID) TO anon;