-- Drop the function first to ensure clean state
DROP FUNCTION IF EXISTS check_unread_notifications(UUID);

-- Recreate the function
CREATE OR REPLACE FUNCTION check_unread_notifications(p_user_id UUID)
RETURNS TABLE (
    unread_matches_count INTEGER,
    unread_messages_count INTEGER,
    latest_match_name TEXT,
    latest_message_sender TEXT,
    latest_message_content TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_unread_matches INTEGER;
    v_unread_messages INTEGER;
    v_latest_match_name TEXT;
    v_latest_message_sender TEXT;
    v_latest_message_content TEXT;
BEGIN
    SET search_path = 'public';

    -- 1. Count unread matches (matches created in the last 2 minutes)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_matches
    FROM matches m
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND m.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get the name of the most recent match
    IF v_unread_matches > 0 THEN
        SELECT 
            CASE 
                WHEN m.user1_id = p_user_id THEN u2.name 
                ELSE u1.name 
            END
        INTO v_latest_match_name
        FROM matches m
        LEFT JOIN users u1 ON m.user1_id = u1.id
        LEFT JOIN users u2 ON m.user2_id = u2.id
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND m.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY m.created_at DESC
        LIMIT 1;
    END IF;

    -- 2. Count unread messages (received in last 2 minutes and unread)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_messages
    FROM chat_messages cm
    JOIN matches m ON cm.match_id = m.id
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND cm.sender_id != p_user_id
      AND cm.read_at IS NULL
      AND cm.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get the sender and content of the most recent message
    IF v_unread_messages > 0 THEN
        SELECT 
            u.name,
            COALESCE(cm.content_translated, cm.content_original)
        INTO v_latest_message_sender, v_latest_message_content
        FROM chat_messages cm
        JOIN matches m ON cm.match_id = m.id
        JOIN users u ON cm.sender_id = u.id
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL
          AND cm.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY cm.created_at DESC
        LIMIT 1;
    END IF;

    RETURN QUERY SELECT 
        COALESCE(v_unread_matches, 0),
        COALESCE(v_unread_messages, 0),
        COALESCE(v_latest_match_name, ''),
        COALESCE(v_latest_message_sender, ''),
        COALESCE(v_latest_message_content, '');
END;
$$;
