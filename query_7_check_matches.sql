-- Check for newly created matches
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT
    m.*,
    u1.name as user_a_name,
    u2.name as user_b_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE m.event_id = '6497a84c-6ae6-445b-b3e1-e7acc984b2c5'
ORDER BY m.created_at DESC
LIMIT 10;