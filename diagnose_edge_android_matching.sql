-- Diagnostic query to check why Edge and Android users aren't matching
-- Edge user: 35fe114e-eae5-49d6-9eba-8459617e7b82
-- Android user: ffc20046-a777-463b-922a-547151aa1455

-- 1. Check user visibility and online status
SELECT
    'Edge User' as user_name,
    id,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    active_modes,
    match_radius_default,
    gender,
    date_of_birth,
    gender_preferences,
    age_preferences,
    strict_gender_age_enforcement
FROM users
WHERE id = '35fe114e-eae5-49d6-9eba-8459617e7b82'

UNION ALL

SELECT
    'Android User' as user_name,
    id,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    active_modes,
    match_radius_default,
    gender,
    date_of_birth,
    gender_preferences,
    age_preferences,
    strict_gender_age_enforcement
FROM users
WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- 2. Check their current locations
SELECT
    'Edge User' as user_name,
    ul.user_id,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_update
FROM user_locations ul
WHERE ul.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
ORDER BY ul.updated_at DESC
LIMIT 1

UNION ALL

SELECT
    'Android User' as user_name,
    ul.user_id,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_update
FROM user_locations ul
WHERE ul.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
ORDER BY ul.updated_at DESC
LIMIT 1;

-- 3. Check their interests
SELECT
    'Edge User' as user_name,
    up.user_id,
    up.profile_data->'interests' as interests
FROM user_profiles up
WHERE up.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND up.profile_data ? 'interests'
LIMIT 1

UNION ALL

SELECT
    'Android User' as user_name,
    up.user_id,
    up.profile_data->'interests' as interests
FROM user_profiles up
WHERE up.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
AND up.profile_data ? 'interests'
LIMIT 1;

-- 4. Check if they are within matching distance
WITH user_locations AS (
    SELECT
        '35fe114e-eae5-49d6-9eba-8459617e7b82' as user1_id,
        'ffc20046-a777-463b-922a-547151aa1455' as user2_id,
        ul1.latitude as lat1,
        ul1.longitude as lng1,
        ul2.latitude as lat2,
        ul2.longitude as lng2,
        u1.match_radius_default as radius_meters
    FROM user_locations ul1
    CROSS JOIN user_locations ul2
    JOIN users u1 ON ul1.user_id = u1.id
    WHERE ul1.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND ul2.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
    AND ul1.updated_at >= NOW() - INTERVAL '1 hour'
    AND ul2.updated_at >= NOW() - INTERVAL '1 hour'
    ORDER BY ul1.updated_at DESC, ul2.updated_at DESC
    LIMIT 1
)
SELECT
    user1_id,
    user2_id,
    lat1,
    lng1,
    lat2,
    lng2,
    radius_meters,
    -- Calculate distance using Haversine formula (approximate)
    6371000 * 2 * ASIN(SQRT(
        POWER(SIN(RADIANS(lat2 - lat1) / 2), 2) +
        COS(RADIANS(lat1)) * COS(RADIANS(lat2)) *
        POWER(SIN(RADIANS(lng2 - lng1) / 2), 2)
    )) as distance_meters,
    CASE
        WHEN 6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(lat2 - lat1) / 2), 2) +
            COS(RADIANS(lat1)) * COS(RADIANS(lat2)) *
            POWER(SIN(RADIANS(lng2 - lng1) / 2), 2)
        )) <= radius_meters THEN 'WITHIN_RANGE'
        ELSE 'OUT_OF_RANGE'
    END as proximity_status
FROM user_locations;

-- 5. Check shared intents
SELECT
    u1.active_modes as edge_intents,
    u2.active_modes as android_intents,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN
            ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes))
        ELSE ARRAY[]::TEXT[]
    END as shared_intents,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN 'HAS_SHARED_INTENTS'
        ELSE 'NO_SHARED_INTENTS'
    END as intent_status
FROM users u1
CROSS JOIN users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455';

-- 6. Check existing matches between these users
SELECT
    'Existing Matches' as check_type,
    COUNT(*) as match_count,
    CASE
        WHEN COUNT(*) > 0 THEN 'ALREADY_MATCHED'
        ELSE 'NO_EXISTING_MATCH'
    END as match_status
FROM matches
WHERE (user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455')
   OR (user1_id = 'ffc20046-a777-463b-922a-547151aa1455' AND user2_id = '35fe114e-eae5-49d6-9eba-8459617e7b82');

-- 7. Test find_nearby_users function directly
SELECT * FROM find_nearby_users(
    '35fe114e-eae5-49d6-9eba-8459617e7b82',
    (SELECT latitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    (SELECT longitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    10.0  -- 10km radius
) WHERE user_id = 'ffc20046-a777-463b-922a-547151aa1455';

-- 8. Check if continuous matching function is running (recent executions)
SELECT
    'Function Status' as check_type,
    COUNT(*) as recent_runs,
    MAX(created_at) as last_run
FROM matches
WHERE created_at >= NOW() - INTERVAL '1 hour';
