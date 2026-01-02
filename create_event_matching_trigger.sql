-- Create trigger to automatically perform event matching when users join events
CREATE OR REPLACE FUNCTION trigger_perform_event_matching()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    -- Only trigger on INSERT (when user joins event)
    IF TG_OP = 'INSERT' THEN
        -- Call the matching function for this event
        PERFORM perform_event_matching(NEW.event_id);
    END IF;
    RETURN NEW;
END;
$$;

-- Create the trigger on event_attendees table
DROP TRIGGER IF EXISTS trigger_event_matching ON event_attendees;
CREATE TRIGGER trigger_event_matching
    AFTER INSERT ON event_attendees
    FOR EACH ROW
    EXECUTE FUNCTION trigger_perform_event_matching();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION trigger_perform_event_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_perform_event_matching() TO anon;