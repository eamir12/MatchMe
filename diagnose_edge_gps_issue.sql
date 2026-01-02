-- Diagnose why Edge browser user is not updating GPS location

-- 1. Check current user visibility and location settings
SELECT
    id,
    email,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    shared_event_matching_enabled,
    smart_gps_throttling_enabled,
    gps_interval_default
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- 2. Check recent location updates for these users
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

-- 3. Check user activity (online status) - should be updating
SELECT
    ua.user_id,
    u.email,
    ua.is_online,
    ua.last_activity,
    EXTRACT(EPOCH FROM (NOW() - ua.last_activity)) / 60 as minutes_since_activity
FROM user_activity ua
INNER JOIN users u ON ua.user_id = u.id
WHERE ua.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- 4. Check if these users are being matched (should show proximity matches if locations are updating)
SELECT
    m.id as match_id,
    m.match_type,
    m.created_at,
    u1.email as user1_email,
    u2.email as user2_email,
    CASE
        WHEN m.user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' OR m.user2_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' THEN 'EDGE_USER_INVOLVED'
        WHEN m.user1_id = 'ffc20046-a777-463b-922a-547151aa1455' OR m.user2_id = 'ffc20046-a777-463b-922a-547151aa1455' THEN 'OTHER_USER_INVOLVED'
        ELSE 'OTHER_USERS'
    END as edge_user_involved
FROM matches m
INNER JOIN users u1 ON m.user1_id = u1.id
INNER JOIN users u2 ON m.user2_id = u2.id
WHERE (m.user1_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    OR m.user2_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455'))
AND m.created_at >= NOW() - INTERVAL '1 hour'
ORDER BY m.created_at DESC;

-- 5. Check if trigger is firing on location updates
SELECT
    trigger_name,
    event_manipulation,
    action_statement
FROM information_schema.triggers
WHERE event_object_table = 'user_locations';
