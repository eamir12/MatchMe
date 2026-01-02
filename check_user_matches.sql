-- Check all matches for the current user
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.event_id,
    m.created_at,
    CASE
        WHEN m.user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' THEN u2.name
        ELSE u1.name
    END as matched_user_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE m.user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
   OR m.user2_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
ORDER BY m.created_at DESC
LIMIT 20;