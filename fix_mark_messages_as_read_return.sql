-- Fix mark_messages_as_read function to return the number of messages marked as read
CREATE OR REPLACE FUNCTION mark_messages_as_read(p_match_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    rows_affected INTEGER;
BEGIN
    SET search_path = 'public';
    
    UPDATE chat_messages
    SET read_at = NOW()
    WHERE match_id = p_match_id
    AND sender_id != auth.uid()
    AND read_at IS NULL;  -- Only update messages that haven't been read yet
    
    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    
    RETURN rows_affected;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO anon;