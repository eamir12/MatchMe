-- Check all matches in the database
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.event_id,
    m.created_at,
    u1.name as user_a_name,
    u2.name as user_b_name,
    e.event_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
LEFT JOIN events e ON m.event_id = e.id
ORDER BY m.created_at DESC
LIMIT 20;