-- Function to find shared events between two users
DROP FUNCTION IF EXISTS find_shared_events(uuid, uuid);
CREATE FUNCTION find_shared_events(user1_id UUID, user2_id UUID)
RETURNS TABLE(event_id UUID, event_name TEXT, start_time TIMESTAMP WITH TIME ZONE)
LANGUAGE plpgsql
AS $$
BEGIN
    SET search_path = 'public';
    RETURN QUERY
    SELECT 
        e.id,
        e.event_name,
        e.start_time
    FROM events e
    WHERE EXISTS (
        SELECT 1 FROM event_attendees ea1 
        WHERE ea1.event_id = e.id AND ea1.user_id = user1_id
    )
    AND EXISTS (
        SELECT 1 FROM event_attendees ea2 
        WHERE ea2.event_id = e.id AND ea2.user_id = user2_id
    )
    ORDER BY e.start_time DESC
    LIMIT 1; -- Return the most recent shared event
END;
$$;