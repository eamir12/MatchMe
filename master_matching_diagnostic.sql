-- Master diagnostic query for Edge/Android matching issue
-- Supabase compatible - returns all diagnostic info in one result set

WITH user_data AS (
    SELECT
        id,
        name,
        COALESCE(user_visibility_setting,false) as user_visibility_setting,
        (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
          AND COALESCE(user_visibility_setting,false) = TRUE
          AND COALESCE(system_visibility_status,'visible') = 'visible')::boolean as is_truly_visible,
        active_modes,
        match_radius_default,
        gender,
        date_of_birth
    FROM users
    WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
),

location_data AS (
    SELECT
        ul.user_id,
        u.name,
        ul.latitude,
        ul.longitude,
        ul.updated_at,
        u.match_radius_default,
        EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
        CASE WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'RECENT' ELSE 'OLD' END as location_status
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    ORDER BY ul.updated_at DESC
),

interest_data AS (
    SELECT
        up.user_id,
        u.name,
        up.profile_data->'interests' as interests
    FROM user_profiles up
    JOIN users u ON up.user_id = u.id
    WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    AND up.profile_data ? 'interests'
),

shared_intents AS (
    SELECT
        u1.id as user1_id,
        u1.name as user1_name,
        u1.active_modes as user1_intents,
        u2.id as user2_id,
        u2.name as user2_name,
        u2.active_modes as user2_intents,
        CASE
            WHEN u1.active_modes IS NULL OR u2.active_modes IS NULL THEN 'NULL_INTENTS'
            WHEN u1.active_modes && u2.active_modes THEN 'HAS_SHARED_INTENTS'
            ELSE 'NO_SHARED_INTENTS'
        END as intent_status,
        CASE
            WHEN u1.active_modes && u2.active_modes THEN
                ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes))
            ELSE ARRAY[]::TEXT[]
        END as shared_intents
    FROM users u1
    CROSS JOIN users u2
    WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455'
),

proximity_calc AS (
    SELECT
        u1.user_id as user1_id,
        u1.name as user1_name,
        u1.latitude as user1_lat,
        u1.longitude as user1_lng,
        u2.user_id as user2_id,
        u2.name as user2_name,
        u2.latitude as user2_lat,
        u2.longitude as user2_lng,
        u1.match_radius_default as user1_radius_meters,
        -- Calculate distance in meters using Haversine formula
        (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) as distance_meters,
        CASE
            WHEN (6371000 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
                COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
                POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
            ))) <= u1.match_radius_default THEN 'WITHIN_RANGE'
            ELSE 'OUT_OF_RANGE'
        END as proximity_status
    FROM location_data u1
    JOIN location_data u2 ON u1.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
                          AND u2.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
                          AND u1.location_status = 'RECENT'
                          AND u2.location_status = 'RECENT'
),

shared_interests_check AS (
    SELECT
        'SHARED_INTERESTS_ANALYSIS' as check_type,
        ui1.name as user1_name,
        ui2.name as user2_name,
        ui1.interests as user1_interests,
        ui2.interests as user2_interests,
        EXISTS (
            SELECT 1
            FROM jsonb_object_keys(ui1.interests) cat
            WHERE ui1.interests ? cat
            AND ui2.interests ? cat
            AND jsonb_array_length(ui1.interests->cat) > 0
            AND jsonb_array_length(ui2.interests->cat) > 0
            AND EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(ui1.interests->cat) i1
                WHERE i1 IN (SELECT jsonb_array_elements_text(ui2.interests->cat))
            )
        ) as has_shared_interests,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM jsonb_object_keys(ui1.interests) cat
                WHERE ui1.interests ? cat
                AND ui2.interests ? cat
                AND jsonb_array_length(ui1.interests->cat) > 0
                AND jsonb_array_length(ui2.interests->cat) > 0
                AND EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements_text(ui1.interests->cat) i1
                    WHERE i1 IN (SELECT jsonb_array_elements_text(ui2.interests->cat))
                )
            ) THEN 'INTERESTS_MATCH'
            ELSE 'NO_SHARED_INTERESTS'
        END as interests_status
    FROM interest_data ui1
    CROSS JOIN interest_data ui2
    WHERE ui1.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND ui2.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
),

existing_matches AS (
    SELECT
        COUNT(*) as existing_match_count,
        CASE WHEN COUNT(*) > 0 THEN 'ALREADY_MATCHED' ELSE 'NO_EXISTING_MATCH' END as match_status
    FROM matches
    WHERE (user1_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455')
       OR (user1_id = 'ffc20046-a777-463b-922a-547151aa1455' AND user2_id = '35fe114e-eae5-49d6-9eba-8459617e7b82')
)

-- USER VISIBILITY SECTION
SELECT
    'USER_VISIBILITY' as section,
    'user_info' as check_type,
    id::TEXT as user_id,
    name as user_name,
    is_truly_visible::TEXT as visibility,
    CASE WHEN active_modes IS NOT NULL THEN 'HAS_INTENTS' ELSE 'NO_INTENTS' END as intent_status,
    active_modes::TEXT as active_modes,
    match_radius_default::TEXT as match_radius
FROM user_data

UNION ALL

-- LOCATION STATUS SECTION
SELECT
    'LOCATION_STATUS' as section,
    'location_info' as check_type,
    user_id::TEXT as user_id,
    name as user_name,
    location_status as visibility,
    minutes_ago::TEXT as intent_status,
    latitude::TEXT || ', ' || longitude::TEXT as active_modes,
    updated_at::TEXT as match_radius
FROM location_data

UNION ALL

-- SHARED INTENTS SECTION
SELECT
    'SHARED_INTENTS' as section,
    'intent_comparison' as check_type,
    user1_id::TEXT as user_id,
    user1_name as user_name,
    intent_status as visibility,
    user2_name as intent_status,
    shared_intents::TEXT as active_modes,
    user2_intents::TEXT as match_radius
FROM shared_intents

UNION ALL

-- PROXIMITY SECTION
SELECT
    'PROXIMITY' as section,
    'distance_calc' as check_type,
    user1_id::TEXT as user_id,
    user1_name as user_name,
    proximity_status as visibility,
    distance_meters::TEXT || ' meters' as intent_status,
    user1_radius_meters::TEXT || 'm radius' as active_modes,
    user2_name as match_radius
FROM proximity_calc

UNION ALL

-- INTERESTS SECTION
SELECT
    'USER_INTERESTS' as section,
    'interest_data' as check_type,
    user_id::TEXT as user_id,
    name as user_name,
    'HAS_INTERESTS' as visibility,
    'N/A' as intent_status,
    interests::TEXT as active_modes,
    'N/A' as match_radius
FROM interest_data

UNION ALL

-- SHARED INTERESTS SECTION
SELECT
    'SHARED_INTERESTS' as section,
    'interest_comparison' as check_type,
    'BOTH_USERS' as user_id,
    user1_name || ' vs ' || user2_name as user_name,
    interests_status as visibility,
    has_shared_interests::TEXT as intent_status,
    'N/A' as active_modes,
    'N/A' as match_radius
FROM shared_interests_check

UNION ALL

-- EXISTING MATCHES SECTION
SELECT
    'EXISTING_MATCHES' as section,
    'match_check' as check_type,
    'BOTH_USERS' as user_id,
    'Edge vs Android' as user_name,
    match_status as visibility,
    existing_match_count::TEXT as intent_status,
    'N/A' as active_modes,
    'N/A' as match_radius
FROM existing_matches

ORDER BY section, check_type;
