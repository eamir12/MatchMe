-- Migration: Fix mark_messages_as_read to update both messages and chats table
-- Created: 2026-02-05

-- Drop the existing function
DROP FUNCTION IF EXISTS mark_messages_as_read(UUID);

-- Create the improved function that updates both tables
CREATE OR REPLACE FUNCTION mark_messages_as_read(p_match_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    rows_affected INTEGER;
    user_id UUID;
    other_user_id UUID;
    current_unread_count INTEGER;
BEGIN
    SET search_path = 'public';
    
    -- Get the current user ID
    user_id := auth.uid();
    
    -- Get the other user ID from the match
    SELECT 
        CASE 
            WHEN user1_id = user_id THEN user2_id
            ELSE user1_id
        END INTO other_user_id
    FROM matches 
    WHERE id = p_match_id;
    
    -- Update messages that haven't been read yet from the other user
    UPDATE chat_messages
    SET read_at = NOW()
    WHERE match_id = p_match_id
    AND sender_id != user_id
    AND read_at IS NULL;
    
    -- Get the number of rows affected
    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    
    -- If we actually marked some messages as read, update the unread count in chats table
    IF rows_affected > 0 THEN
        -- Get current unread count for the user in this chat
        SELECT unread_count INTO current_unread_count
        FROM chats 
        WHERE user_id = user_id AND match_id = p_match_id;
        
        -- Update the unread count for the current user
        UPDATE chats 
        SET unread_count = GREATEST(0, unread_count - rows_affected),
            updated_at = NOW()
        WHERE user_id = user_id AND match_id = p_match_id;
        
        -- Also update the other user's chat entry if it exists
        UPDATE chats 
        SET updated_at = NOW()
        WHERE user_id = other_user_id AND match_id = p_match_id;
    END IF;
    
    RETURN rows_affected;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO anon;