-- Create function to perform event matching for all events continuously
CREATE OR REPLACE FUNCTION perform_continuous_event_matching()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    event_record RECORD;
BEGIN
    SET search_path = 'public';

    -- Loop through all events that have attendees
    FOR event_record IN
        SELECT DISTINCT e.id
        FROM events e
        INNER JOIN event_attendees ea ON e.id = ea.event_id
        WHERE e.event_date >= CURRENT_DATE  -- Only future or current events
        ORDER BY e.event_date ASC
    LOOP
        -- Perform matching for this event
        PERFORM perform_event_matching(event_record.id);
    END LOOP;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION perform_continuous_event_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION perform_continuous_event_matching() TO anon;