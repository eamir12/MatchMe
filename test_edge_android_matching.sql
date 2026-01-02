-- Test script to manually trigger continuous user matching for Edge and Android users

-- First, check current state before running matching
SELECT
    'BEFORE MATCHING' as phase,
    COUNT(*) as total_matches,
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '1 minute') as matches_last_minute
FROM matches;

-- Check if the two users are visible and have recent locations
SELECT
    u.id,
    u.name,
    COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
    COALESCE(u.system_visibility_status,'visible') as system_visibility_status,
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
      AND COALESCE(u.user_visibility_setting,false) = TRUE
      AND COALESCE(u.system_visibility_status,'visible') = 'visible')::boolean as is_truly_visible,
    u.active_modes,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_location_update
FROM users u
LEFT JOIN user_locations ul ON u.id = ul.user_id
    AND ul.updated_at >= NOW() - INTERVAL '1 hour'  -- Only recent locations
WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Manually trigger the continuous user matching function
SELECT * FROM perform_continuous_user_matching();

-- Check if any new matches were created
SELECT
    'AFTER MATCHING' as phase,
    COUNT(*) as total_matches,
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '1 minute') as matches_last_minute
FROM matches;

-- Check for new matches involving our test users
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.created_at,
    u1.name as user1_name,
    u2.name as user2_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE (m.user1_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
   OR m.user2_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455'))
   AND m.created_at >= NOW() - INTERVAL '5 minutes'
ORDER BY m.created_at DESC;
