-- Check for event matches in the database
SELECT id, user1_id, user2_id, match_type, event_id, created_at
FROM matches
WHERE match_type = 'event'
ORDER BY created_at DESC
LIMIT 10;