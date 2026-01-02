-- Check if location data is being synced from local DB to Supabase

-- 1. Check current location records for both users
SELECT
    ul.user_id,
    u.email,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_update
FROM user_locations ul
INNER JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- 2. Check if there are any recent proximity matches (should happen when locations are updated)
SELECT
    m.id as match_id,
    m.match_type,
    m.created_at,
    u1.email as user1_email,
    u2.email as user2_email,
    m.matched_intent
FROM matches m
INNER JOIN users u1 ON m.user1_id = u1.id
INNER JOIN users u2 ON m.user2_id = u2.id
WHERE m.match_type = 'proximity'
AND m.created_at >= NOW() - INTERVAL '30 minutes'
ORDER BY m.created_at DESC;
