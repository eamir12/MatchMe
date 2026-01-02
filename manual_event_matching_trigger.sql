-- ===========================================
-- MANUAL EVENT MATCHING TRIGGER
-- Run each section separately in Supabase SQL Editor
-- ===========================================

-- QUERY 1: Find events both users are attending
SELECT
    ea.event_id,
    e.event_name,
    COUNT(*) as attendee_count
FROM event_attendees ea
JOIN events e ON ea.event_id = e.id
WHERE ea.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
GROUP BY ea.event_id, e.event_name
HAVING COUNT(*) = 2; -- Both users attending

-- ===========================================
-- QUERY 2: Manual trigger for event matching
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT perform_event_matching('6497a84c-6ae6-445b-b3e1-e7acc984b2c5');

-- ===========================================
-- QUERY 3: Check if the match was created
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.event_id,
    m.created_at
FROM matches m
WHERE m.event_id = '6497a84c-6ae6-445b-b3e1-e7acc984b2c5'
ORDER BY m.created_at DESC
LIMIT 5;