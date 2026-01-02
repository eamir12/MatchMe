-- Create the mark_messages_as_read function
DROP FUNCTION IF EXISTS mark_messages_as_read(UUID);
CREATE OR REPLACE FUNCTION mark_messages_as_read(p_match_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    UPDATE chat_messages
    SET read_at = NOW()
    WHERE match_id = p_match_id
    AND sender_id != auth.uid();
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO anon;