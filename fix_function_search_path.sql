-- Fix function search path mutable issues by adding SET search_path = 'public' to all affected functions

-- Create or update the trigger_set_timestamp function with secure search_path
CREATE OR REPLACE FUNCTION trigger_set_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Create or update the count_event_attendees function with secure search_path
CREATE OR REPLACE FUNCTION count_event_attendees(p_event_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    attendee_count INTEGER;
BEGIN
    SET search_path = 'public';
    SELECT COUNT(*)
    INTO attendee_count
    FROM event_attendees
    WHERE event_id = p_event_id;
    RETURN COALESCE(attendee_count, 0);
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION trigger_set_timestamp() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_set_timestamp() TO anon;
GRANT EXECUTE ON FUNCTION count_event_attendees(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION count_event_attendees(UUID) TO anon;