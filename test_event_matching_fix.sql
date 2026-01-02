-- Test the fixed event matching function
-- This should show that matches are no longer created when users have event matching disabled

-- 1. Check current user settings (should show both users have event matching disabled)
SELECT
    email,
    shared_event_matching_enabled,
    COALESCE(user_visibility_setting,false) as user_visibility_setting
FROM users
WHERE shared_event_matching_enabled IS NOT NULL
ORDER BY email;

-- 2. Check existing event matches (should not create new ones when both users have it disabled)
SELECT
    COUNT(*) as total_event_matches,
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '1 hour') as recent_event_matches
FROM matches
WHERE match_type = 'event';

-- 3. Test the function with a mock event (should not create matches)
-- First, create a test event if needed
INSERT INTO events (id, event_name, event_description, event_date, event_location, created_by)
VALUES (
    gen_random_uuid(),
    'Test Event for Matching',
    'Testing event matching with disabled users',
    NOW() + INTERVAL '1 day',
    '{"latitude": 40.7128, "longitude": -74.0060}',
    (SELECT id FROM users LIMIT 1)
)
ON CONFLICT DO NOTHING;

-- Get the test event ID
DO $$
DECLARE
    test_event_id UUID;
    user1_id UUID;
    user2_id UUID;
BEGIN
    -- Get test event
    SELECT id INTO test_event_id
    FROM events
    WHERE event_name = 'Test Event for Matching'
    LIMIT 1;

    IF test_event_id IS NULL THEN
        RAISE NOTICE 'Test event not found';
        RETURN;
    END IF;

    -- Get two users
    SELECT id INTO user1_id FROM users WHERE shared_event_matching_enabled = false LIMIT 1;
    SELECT id INTO user2_id FROM users WHERE shared_event_matching_enabled = false AND id != user1_id LIMIT 1;

    IF user1_id IS NULL OR user2_id IS NULL THEN
        RAISE NOTICE 'Not enough test users found';
        RETURN;
    END IF;

    RAISE NOTICE 'Testing with users: % and %', user1_id, user2_id;

    -- Add users to event
    INSERT INTO event_attendees (event_id, user_id, joined_at)
    VALUES (test_event_id, user1_id, NOW())
    ON CONFLICT DO NOTHING;

    INSERT INTO event_attendees (event_id, user_id, joined_at)
    VALUES (test_event_id, user2_id, NOW())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE 'Added users to test event. The trigger should NOT create a match since both have event matching disabled.';

    -- Call the function manually to test (the trigger should also call it)
    PERFORM perform_event_matching(test_event_id);

    RAISE NOTICE 'Function called. Check if any new matches were created...';
END $$;

-- 4. Check if any new matches were created (should be 0)
SELECT
    COUNT(*) as new_event_matches_after_test
FROM matches
WHERE match_type = 'event'
AND created_at >= NOW() - INTERVAL '1 minute';

-- 5. Now test with event matching enabled (create a match)
DO $$
DECLARE
    test_event_id UUID;
    user1_id UUID;
    user2_id UUID;
BEGIN
    -- Enable event matching for two users temporarily
    UPDATE users SET shared_event_matching_enabled = true WHERE id IN (
        SELECT id FROM users LIMIT 2
    );

    -- Get test event
    SELECT id INTO test_event_id
    FROM events
    WHERE event_name = 'Test Event for Matching'
    LIMIT 1;

    IF test_event_id IS NULL THEN
        RAISE NOTICE 'Test event not found for second test';
        RETURN;
    END IF;

    RAISE NOTICE 'Testing with event matching ENABLED...';

    -- Call the function again
    PERFORM perform_event_matching(test_event_id);

    RAISE NOTICE 'Function called with event matching enabled. Check for new matches...';

    -- Reset the setting
    UPDATE users SET shared_event_matching_enabled = false WHERE shared_event_matching_enabled = true;
END $$;

-- 6. Final check - should now show new matches created when users had it enabled
SELECT
    COUNT(*) as final_event_matches,
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '1 minute') as very_recent_matches
FROM matches
WHERE match_type = 'event';
