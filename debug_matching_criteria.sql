-- Debug why Edge and Android users aren't matching

-- Check user visibility and basic info
SELECT
    'USER VISIBILITY' as check_type,
    id,
    name,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    active_modes,
    match_radius_default,
    gender,
    date_of_birth
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- Check recent locations (last 24 hours)
SELECT
    'RECENT LOCATIONS' as check_type,
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
    CASE
        WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'RECENT (within 1h)'
        ELSE 'OLD (over 1h ago)'
    END as location_status
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Check distance between users
WITH user_locs AS (
    SELECT
        ul.user_id,
        u.name,
        ul.latitude,
        ul.longitude,
        ul.updated_at,
        u.match_radius_default
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    AND ul.updated_at >= NOW() - INTERVAL '1 hour'
    ORDER BY ul.updated_at DESC
)
SELECT
    'PROXIMITY CHECK' as check_type,
    u1.user_id as user1_id,
    u1.name as user1_name,
    u1.latitude as user1_lat,
    u1.longitude as user1_lng,
    u2.user_id as user2_id,
    u2.name as user2_name,
    u2.latitude as user2_lat,
    u2.longitude as user2_lng,
    -- Calculate distance in meters
    (6371000 * 2 * ASIN(SQRT(
        POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
        COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
        POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
    ))) as distance_meters,
    u1.match_radius_default as user1_radius_meters,
    CASE
        WHEN (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) <= u1.match_radius_default THEN 'WITHIN_RANGE'
        ELSE 'OUT_OF_RANGE'
    END as proximity_status
FROM user_locs u1
CROSS JOIN user_locs u2
WHERE u1.user_id < u2.user_id; -- Avoid duplicate pairs

-- Check shared intents
SELECT
    'SHARED INTENTS' as check_type,
    u1.id as user1_id,
    u1.name as user1_name,
    u1.active_modes as user1_intents,
    u2.id as user2_id,
    u2.name as user2_name,
    u2.active_modes as user2_intents,
    CASE
        WHEN u1.active_modes IS NULL OR u2.active_modes IS NULL THEN 'NULL_INTENTS'
        WHEN u1.active_modes && u2.active_modes THEN 'HAS_SHARED'
        ELSE 'NO_SHARED'
    END as intent_status,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN
            ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes))
        ELSE ARRAY[]::TEXT[]
    END as shared_intents
FROM users u1
CROSS JOIN users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Check interests
SELECT
    'INTERESTS' as check_type,
    up.user_id,
    u.name,
    up.profile_data->'interests' as interests
FROM user_profiles up
JOIN users u ON up.user_id = u.id
WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
AND up.profile_data ? 'interests';

-- Check existing matches
SELECT
    'EXISTING MATCHES' as check_type,
    COUNT(*) as existing_matches_between_users
FROM matches
WHERE (user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455')
   OR (user1_id = 'ffc20046-a777-463b-922a-547151aa1455' AND user2_id = '35fe114e-eae5-49d6-9eba-8459617e7b82');

-- Test find_nearby_users function directly
SELECT
    'FIND_NEARBY_USERS TEST' as check_type,
    fnu.*
FROM find_nearby_users(
    '35fe114e-eae5-49d6-9eba-8459617e7b82',
    (SELECT latitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    (SELECT longitude FROM user_locations WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' ORDER BY updated_at DESC LIMIT 1),
    (SELECT match_radius_default / 1000.0 FROM users WHERE id = '35fe114e-eae5-49d6-9eba-8459617e7b82')::DOUBLE PRECISION
) fnu;
