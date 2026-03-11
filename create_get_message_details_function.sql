-- Function to get details of a specific message for notifications
-- This avoids the "2 minute" race condition and ensures we get the exact message
CREATE OR REPLACE FUNCTION get_message_details(p_message_id UUID)
RETURNS TABLE (
    sender_name TEXT,
    content TEXT,
    sender_id UUID,
    match_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    
    RETURN QUERY
    SELECT 
        public.mask_full_name(up.profile_data->>'fullName') as sender_name,
        COALESCE(cm.content_translated, cm.content_original) as content,
        cm.sender_id,
        cm.match_id
    FROM chat_messages cm
    JOIN user_profiles up ON up.user_id = cm.sender_id
    WHERE cm.id = p_message_id;
END;
$$;
