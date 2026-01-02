-- Quick debug to find why Edge/Android users aren't matching

-- 1. Check visibility and intents
SELECT
    id,
    name,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    COALESCE(system_visibility_status,'visible') as system_visibility_status,
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
      AND COALESCE(user_visibility_setting,false) = TRUE
      AND COALESCE(system_visibility_status,'visible') = 'visible')::boolean as is_truly_visible,
    active_modes
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- 2. Check recent locations (must be within 1 hour)
SELECT
    ul.user_id,
    u.name,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
    CASE WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'RECENT' ELSE 'OLD' END as status
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- 3. Check shared intents
SELECT
    u1.name as user1,
    u1.active_modes as user1_intents,
    u2.name as user2,
    u2.active_modes as user2_intents,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN 'SHARED'
        ELSE 'NO SHARED INTENTS'
    END as intent_check
FROM users u1, users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455';

-- 4. Check interests
SELECT
    u.name,
    up.profile_data->'interests' as interests
FROM user_profiles up
JOIN users u ON up.user_id = u.id
WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
AND up.profile_data ? 'interests';

-- 5. Test proximity search directly
SELECT * FROM find_nearby_users(
    '35fe114e-eae5-49d6-9eba-8459617e7b82',
    (SELECT latitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    (SELECT longitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    10.0
) WHERE user_id = 'ffc20046-a777-463b-922a-547151aa1455';
