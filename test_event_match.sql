-- Test: Create a sample event match for testing the UI feature
-- This will create a match with match_type = 'event' and event_id

-- First, let's see what events exist
SELECT id, event_name, start_time FROM events LIMIT 5;

-- Then create a test match (replace with actual user IDs and event ID)
-- INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
-- VALUES ('user1_id_here', 'user2_id_here', 'event', 'some_intent', 'event_id_here', NOW());