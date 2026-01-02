-- Manual test of continuous event matching
-- Run this in your Supabase SQL Editor to test the function

SELECT * FROM perform_continuous_event_matching();

-- Check what happened
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.event_id,
    m.created_at,
    e.title as event_title
FROM matches m
LEFT JOIN events e ON m.event_id = e.id
WHERE m.created_at >= NOW() - INTERVAL '5 minutes'
ORDER BY m.created_at DESC;