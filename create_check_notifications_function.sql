-- Function to check for unread notifications (matches and messages)
-- Updated to support fetching a specific message by ID for instant Realtime delivery
CREATE OR REPLACE FUNCTION check_unread_notifications(p_user_id UUID, p_message_id UUID DEFAULT NULL)
RETURNS TABLE (
    unread_matches_count INTEGER,
    unread_messages_count INTEGER,
    latest_match_name TEXT,
    latest_message_sender TEXT,
    latest_message_content TEXT,
    latest_message_id UUID,
    latest_match_id UUID,
    latest_sender_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_unread_matches INTEGER := 0;
    v_unread_messages INTEGER := 0;
    v_latest_match_name TEXT;
    v_latest_message_sender TEXT;
    v_latest_message_content TEXT;
    v_latest_message_id UUID;
    v_latest_match_id UUID;
    v_latest_sender_id UUID;
BEGIN
    SET search_path = 'public';

    -- If a specific message ID is provided (from Realtime), fetch it directly
    IF p_message_id IS NOT NULL THEN
        SELECT 
            COALESCE(public.mask_full_name(u.name), 'Unknown User'),
            COALESCE(cm.content_translated, cm.content_original),
            cm.id,
            cm.match_id,
            cm.sender_id
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id
        FROM chat_messages cm
        LEFT JOIN public.users u ON u.id = cm.sender_id
        WHERE cm.id = p_message_id;

        IF FOUND THEN
            v_unread_messages := 1;
            RETURN QUERY SELECT 
                0, 
                1, 
                NULL::TEXT, 
                v_latest_message_sender, 
                v_latest_message_content,
                v_latest_message_id,
                v_latest_match_id,
                v_latest_sender_id;
            RETURN;
        END IF;
    END IF;

    -- Fallback to polling logic (check recent unread)
    
    -- 1. Count unread matches (last 2 minutes)
    SELECT COUNT(*)
    INTO v_unread_matches
    FROM matches m
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND m.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get the name of the most recent match
    IF v_unread_matches > 0 THEN
        SELECT 
            COALESCE(public.mask_full_name(u.name), 'Unknown User')
        INTO v_latest_match_name
        FROM matches m
        LEFT JOIN public.users u ON u.id = CASE 
            WHEN m.user1_id = p_user_id THEN m.user2_id 
            ELSE m.user1_id 
        END
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND m.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY m.created_at DESC
        LIMIT 1;
    END IF;

    -- 2. Count unread messages (last 2 minutes) - MUST have read_at IS NULL
    SELECT COUNT(*)
    INTO v_unread_messages
    FROM chat_messages cm
    WHERE cm.match_id IN (SELECT id FROM matches WHERE user1_id = p_user_id OR user2_id = p_user_id)
      AND cm.sender_id != p_user_id
      AND cm.read_at IS NULL
      AND cm.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get latest message details - MUST be unread (read_at IS NULL)
    IF v_unread_messages > 0 THEN
        SELECT 
            COALESCE(public.mask_full_name(u.name), 'Unknown User'),
            COALESCE(cm.content_translated, cm.content_original),
            cm.id,
            cm.match_id,
            cm.sender_id
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id
        FROM chat_messages cm
        LEFT JOIN public.users u ON u.id = cm.sender_id
        WHERE cm.match_id IN (SELECT id FROM matches WHERE user1_id = p_user_id OR user2_id = p_user_id)
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL
          AND cm.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY cm.created_at DESC
        LIMIT 1;
    END IF;

    RETURN QUERY SELECT 
        COALESCE(v_unread_matches, 0), 
        COALESCE(v_unread_messages, 0), 
        v_latest_match_name, 
        v_latest_message_sender, 
        v_latest_message_content,
        v_latest_message_id,
        v_latest_match_id,
        v_latest_sender_id;
END;
$$;