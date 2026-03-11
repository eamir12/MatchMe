-- Fix for ambiguous check_unread_notifications function
-- Drops both existing signatures and recreates a single, robust function
-- Renames latest_sender_id to latest_message_sender_id to match Android client expectations

-- Drop both potential signatures to be absolutely safe
DROP FUNCTION IF EXISTS check_unread_notifications(UUID);
DROP FUNCTION IF EXISTS check_unread_notifications(UUID, UUID);

-- Create the comprehensive version that handles both polling and realtime checks
CREATE OR REPLACE FUNCTION check_unread_notifications(p_user_id UUID, p_message_id UUID DEFAULT NULL)
RETURNS TABLE (
    unread_matches_count INTEGER,
    unread_messages_count INTEGER,
    latest_match_name TEXT,
    latest_message_sender TEXT,
    latest_message_content TEXT,
    latest_message_id UUID,
    latest_match_id UUID,
    latest_message_sender_id UUID,
    translation_enabled BOOLEAN,
    translation_language TEXT,
    translation_available BOOLEAN
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
    v_translation_enabled BOOLEAN;
    v_translation_language TEXT;
    v_translation_available BOOLEAN;
BEGIN
    SET search_path = 'public';

    -- If a specific message ID is provided (from Realtime), fetch it directly
    IF p_message_id IS NOT NULL THEN
        SELECT 
            public.mask_full_name(
                COALESCE(up.profile_data->>'fullName', u.name)
            ),
            CASE 
                WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
                ELSE cm.content_original
            END,
            cm.id,
            cm.match_id,
            cm.sender_id,
            COALESCE(c.translation_enabled, false),
            c.translation_language,
            (cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null')
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_enabled, v_translation_language, v_translation_available
        FROM chat_messages cm
        LEFT JOIN user_profiles up ON up.user_id = cm.sender_id
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
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
                v_latest_sender_id,
                v_translation_enabled,
                v_translation_language,
                v_translation_available;
            RETURN;
        END IF;
    END IF;

    -- Fallback to polling logic (check recent unread)
    
    -- 1. Count unread matches (last 2 minutes)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_matches
    FROM matches m
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND m.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get the name of the most recent match
    IF v_unread_matches > 0 THEN
        SELECT 
            public.mask_full_name(
                COALESCE(up.profile_data->>'fullName', u.name)
            ),
            m.id
        INTO v_latest_match_name, v_latest_match_id
        FROM matches m
        LEFT JOIN user_profiles up ON up.user_id = CASE 
            WHEN m.user1_id = p_user_id THEN m.user2_id 
            ELSE m.user1_id 
        END
        LEFT JOIN public.users u ON u.id = CASE 
            WHEN m.user1_id = p_user_id THEN m.user2_id 
            ELSE m.user1_id 
        END
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND m.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY m.created_at DESC
        LIMIT 1;
    END IF;

    -- 2. Count unread messages (received in last 2 minutes and unread)
    -- Using read_at IS NULL to determine unread status
    SELECT COUNT(*)::INTEGER
    INTO v_unread_messages
    FROM chat_messages cm
    JOIN matches m ON cm.match_id = m.id
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND cm.sender_id != p_user_id
      AND cm.read_at IS NULL
      AND cm.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get latest message details with translation info
    IF v_unread_messages > 0 THEN
        SELECT 
            public.mask_full_name(
                COALESCE(up.profile_data->>'fullName', u.name)
            ),
            CASE 
                WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
                ELSE cm.content_original
            END,
            cm.id,
            cm.match_id,
            cm.sender_id,
            COALESCE(c.translation_enabled, false),
            c.translation_language,
            (cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null')
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_enabled, v_translation_language, v_translation_available
        FROM chat_messages cm
        JOIN matches m ON cm.match_id = m.id
        LEFT JOIN user_profiles up ON up.user_id = cm.sender_id
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
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
        v_latest_match_name, 
        v_latest_message_sender, 
        v_latest_message_content, 
        v_latest_message_id,
        v_latest_match_id,
        v_latest_sender_id, -- Matches latest_message_sender_id in table definition order
        v_translation_enabled,
        v_translation_language,
        v_translation_available;
END;
$$;
