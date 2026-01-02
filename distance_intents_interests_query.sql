-- Supabase query that computes distance, shared intents, and shared interests
-- for Edge user (35fe114e-eae5-49d6-9eba-8459617e7b82) and Android user (ffc20046-a777-463b-922a-547151aa1455)
-- Includes match radius settings for both users

-- All queries standardized to have exactly 7 columns

-- 1. DISTANCE CALCULATION (Proximity)
SELECT
    'DISTANCE_CALCULATION' as calculation_type,
    u1.name as user1_name,
    u2.name as user2_name,
    (u1.latitude || ', ' || u1.longitude || ' (radius: ' || u1.match_radius_default || 'm)')::TEXT as user1_coordinates,
    (u2.latitude || ', ' || u2.longitude || ' (radius: ' || u2.match_radius_default || 'm)')::TEXT as user2_coordinates,
    ROUND((6371000 * 2 * ASIN(SQRT(
        POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
        COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
        POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
    ))))::TEXT || ' meters apart' as distance_value,
    CASE
        WHEN (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) <= LEAST(u1.match_radius_default, u2.match_radius_default) THEN 'WITHIN_RANGE (using smaller radius: ' || LEAST(u1.match_radius_default, u2.match_radius_default) || 'm)'
        ELSE 'OUT_OF_RANGE (needs to be within ' || LEAST(u1.match_radius_default, u2.match_radius_default) || 'm)'
    END as status
FROM (
    SELECT ul.user_id, u.name, ul.latitude, ul.longitude, u.match_radius_default
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND ul.updated_at >= NOW() - INTERVAL '1 hour'
    ORDER BY ul.updated_at DESC LIMIT 1
) u1
CROSS JOIN (
    SELECT ul.user_id, u.name, ul.latitude, ul.longitude, u.match_radius_default
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
    AND ul.updated_at >= NOW() - INTERVAL '1 hour'
    ORDER BY ul.updated_at DESC LIMIT 1
) u2

UNION ALL

-- 1.5. MATCH RADIUS SETTINGS
SELECT
    'MATCH_RADIUS_SETTINGS' as calculation_type,
    u1.name as user1_name,
    u2.name as user2_name,
    u1.match_radius_default::TEXT || ' meters' as user1_radius,
    u2.match_radius_default::TEXT || ' meters' as user2_radius,
    'For matching: uses ' || LEAST(u1.match_radius_default, u2.match_radius_default)::TEXT || 'm (smaller radius)' as effective_radius,
    CASE
        WHEN u1.match_radius_default = u2.match_radius_default THEN 'EQUAL_RADII'
        WHEN u1.match_radius_default < u2.match_radius_default THEN u1.name || ' has smaller radius'
        ELSE u2.name || ' has smaller radius'
    END as radius_comparison
FROM users u1
CROSS JOIN users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455'

UNION ALL

-- 2. SHARED INTENTS CALCULATION
SELECT
    'SHARED_INTENTS' as calculation_type,
    u1.name as user1_name,
    u2.name as user2_name,
    u1.active_modes::TEXT as user1_intents,
    u2.active_modes::TEXT as user2_intents,
    CASE
        WHEN u1.active_modes IS NULL OR u2.active_modes IS NULL THEN 'NULL_INTENTS'
        WHEN u1.active_modes && u2.active_modes THEN
            ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes))::TEXT
        ELSE 'NO_OVERLAP'
    END as shared_intents,
    CASE
        WHEN u1.active_modes IS NULL OR u2.active_modes IS NULL THEN 'NULL_INTENTS'
        WHEN u1.active_modes && u2.active_modes THEN 'HAS_SHARED_INTENTS (' || ARRAY_LENGTH(ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes)), 1) || ' in common)'
        ELSE 'NO_SHARED_INTENTS'
    END as status
FROM users u1
CROSS JOIN users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455'

UNION ALL

-- 3. SHARED INTERESTS CALCULATION
SELECT
    'SHARED_INTERESTS' as calculation_type,
    ui1.name as user1_name,
    ui2.name as user2_name,
    ui1.interests::TEXT as user1_interests,
    ui2.interests::TEXT as user2_interests,
    'N/A' as shared_intents,
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
        ) THEN 'INTERESTS_MATCH - Users have overlapping interests in at least one category'
        ELSE 'NO_SHARED_INTERESTS - No overlapping interests found'
    END as status
FROM (
    SELECT u.name, up.profile_data->'interests' as interests
    FROM user_profiles up
    JOIN users u ON up.user_id = u.id
    WHERE up.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND up.profile_data ? 'interests'
    LIMIT 1
) ui1
CROSS JOIN (
    SELECT u.name, up.profile_data->'interests' as interests
    FROM user_profiles up
    JOIN users u ON up.user_id = u.id
    WHERE up.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
    AND up.profile_data ? 'interests'
    LIMIT 1
) ui2;
