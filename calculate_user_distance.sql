-- Calculate distance between two users
-- Replace the user IDs below with your actual test user IDs

-- Option 1: Get the MOST RECENT locations (regardless of how old they are)
-- This is useful to see the current state even if locations are stale
WITH latest_locations AS (
    SELECT DISTINCT ON (ul.user_id)
        ul.user_id,
        u.name,
        ul.latitude,
        ul.longitude,
        ul.updated_at,
        EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
        u.match_radius_default
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id IN (
        '35fe114e-eae5-49d6-9eba-8459617e7b82',  -- Edge user (replace with actual ID)
        'ffc20046-a777-463b-922a-547151aa1455'   -- Android user (replace with actual ID)
    )
    ORDER BY ul.user_id, ul.updated_at DESC
)
SELECT
    u1.user_id as user1_id,
    u1.name as user1_name,
    u1.latitude as user1_latitude,
    u1.longitude as user1_longitude,
    u1.updated_at as user1_updated_at,
    ROUND(u1.minutes_ago, 1) as user1_minutes_ago,
    u2.user_id as user2_id,
    u2.name as user2_name,
    u2.latitude as user2_latitude,
    u2.longitude as user2_longitude,
    u2.updated_at as user2_updated_at,
    ROUND(u2.minutes_ago, 1) as user2_minutes_ago,
    -- Calculate distance using Haversine formula (accurate for short distances)
    -- Distance in meters
    ROUND(
        (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        )))::NUMERIC, 2
    ) as distance_meters,
    -- Distance in kilometers
    ROUND(
        ((6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) / 1000)::NUMERIC, 2
    ) as distance_kilometers,
    -- Distance in miles
    ROUND(
        ((6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) / 1609.34)::NUMERIC, 2
    ) as distance_miles,
    u1.match_radius_default as user1_match_radius_meters,
    u2.match_radius_default as user2_match_radius_meters,
    LEAST(u1.match_radius_default, u2.match_radius_default) as effective_match_radius_meters,
    CASE
        WHEN (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) <= LEAST(u1.match_radius_default, u2.match_radius_default) 
        THEN 'WITHIN_MATCH_RANGE'
        ELSE 'OUT_OF_MATCH_RANGE'
    END as match_range_status
FROM latest_locations u1
CROSS JOIN latest_locations u2
WHERE u1.user_id < u2.user_id;

-- Option 2: Only include locations updated within the last hour
-- Uncomment the section below if you want to filter by recency
/*
WITH latest_locations AS (
    SELECT DISTINCT ON (ul.user_id)
        ul.user_id,
        u.name,
        ul.latitude,
        ul.longitude,
        ul.updated_at,
        EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
        u.match_radius_default
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id IN (
        '35fe114e-eae5-49d6-9eba-8459617e7b82',  -- Edge user
        'ffc20046-a777-463b-922a-547151aa1455'   -- Android user
    )
    AND ul.updated_at >= NOW() - INTERVAL '1 hour'  -- Only recent locations
    ORDER BY ul.user_id, ul.updated_at DESC
)
SELECT
    u1.user_id as user1_id,
    u1.name as user1_name,
    u1.latitude as user1_latitude,
    u1.longitude as user1_longitude,
    u1.updated_at as user1_updated_at,
    ROUND(u1.minutes_ago, 1) as user1_minutes_ago,
    u2.user_id as user2_id,
    u2.name as user2_name,
    u2.latitude as user2_latitude,
    u2.longitude as user2_longitude,
    u2.updated_at as user2_updated_at,
    ROUND(u2.minutes_ago, 1) as user2_minutes_ago,
    -- Calculate distance using Haversine formula
    ROUND(
        (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        )))::NUMERIC, 2
    ) as distance_meters,
    ROUND(
        ((6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) / 1000)::NUMERIC, 2
    ) as distance_kilometers,
    ROUND(
        ((6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) / 1609.34)::NUMERIC, 2
    ) as distance_miles,
    u1.match_radius_default as user1_match_radius_meters,
    u2.match_radius_default as user2_match_radius_meters,
    LEAST(u1.match_radius_default, u2.match_radius_default) as effective_match_radius_meters,
    CASE
        WHEN (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) <= LEAST(u1.match_radius_default, u2.match_radius_default) 
        THEN 'WITHIN_MATCH_RANGE'
        ELSE 'OUT_OF_MATCH_RANGE'
    END as match_range_status
FROM latest_locations u1
CROSS JOIN latest_locations u2
WHERE u1.user_id < u2.user_id;
*/
