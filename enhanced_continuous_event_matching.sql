-- Enhanced continuous event matching function with logging
CREATE OR REPLACE FUNCTION perform_continuous_event_matching()
RETURNS TABLE (
    event_processed UUID,
    attendees_found INTEGER,
    matches_created INTEGER,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    event_record RECORD;
    attendee_count INTEGER := 0;
    match_count INTEGER := 0;
    total_matches INTEGER := 0;
BEGIN
    SET search_path = 'public';

    RAISE NOTICE 'Starting continuous event matching at %', NOW();

    -- Loop through all events that have attendees
    FOR event_record IN
        SELECT DISTINCT e.id, e.title, e.event_date
        FROM events e
        INNER JOIN event_attendees ea ON e.id = ea.event_id
        WHERE e.event_date >= CURRENT_DATE  -- Only future or current events
        ORDER BY e.event_date ASC
    LOOP
        RAISE NOTICE 'Processing event: % (ID: %)', event_record.title, event_record.id;

        -- Count attendees for this event
        SELECT COUNT(*) INTO attendee_count
        FROM event_attendees
        WHERE event_id = event_record.id;

        RAISE NOTICE 'Event % has % attendees', event_record.id, attendee_count;

        -- Only process if there are at least 2 attendees
        IF attendee_count >= 2 THEN
            -- Perform matching for this event
            BEGIN
                PERFORM perform_event_matching(event_record.id);
                RAISE NOTICE 'Successfully processed matching for event %', event_record.id;

                -- Count new matches created for this event (rough estimate)
                SELECT COUNT(*) INTO match_count
                FROM matches
                WHERE event_id = event_record.id
                AND created_at >= NOW() - INTERVAL '1 minute';

                total_matches := total_matches + match_count;

                RETURN QUERY SELECT
                    event_record.id,
                    attendee_count,
                    match_count,
                    'processed'::TEXT;

            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error processing event %: %', event_record.id, SQLERRM;
                RETURN QUERY SELECT
                    event_record.id,
                    attendee_count,
                    0,
                    'error: ' || SQLERRM;
            END;
        ELSE
            RAISE NOTICE 'Skipping event % - not enough attendees (% < 2)', event_record.id, attendee_count;
            RETURN QUERY SELECT
                event_record.id,
                attendee_count,
                0,
                'skipped: insufficient attendees'::TEXT;
        END IF;
    END LOOP;

    RAISE NOTICE 'Continuous event matching completed. Total matches created: %', total_matches;

    -- Return summary if no events were processed
    IF NOT FOUND THEN
        RETURN QUERY SELECT
            NULL::UUID,
            0,
            total_matches,
            'no events to process'::TEXT;
    END IF;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION perform_continuous_event_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION perform_continuous_event_matching() TO anon;