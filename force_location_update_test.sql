-- Force a location update test
-- This simulates what should happen when users update their locations

-- First, let's see the current stored locations
SELECT
    'CURRENT_STORED_LOCATIONS' as check_type,
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_old
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Simulate location update by inserting new location data
-- Replace these coordinates with the actual current coordinates if known
-- For now, I'll simulate them being very close (same building)

-- Edge user simulated location update
INSERT INTO user_locations (user_id, latitude, longitude, updated_at)
VALUES ('35fe114e-eae5-49d6-9eba-8459617e7b82', 41.297300, -72.787200, NOW())
ON CONFLICT (user_id)
DO UPDATE SET
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    updated_at = EXCLUDED.updated_at;

-- Android user simulated location update
INSERT INTO user_locations (user_id, latitude, longitude, updated_at)
VALUES ('ffc20046-a777-463b-922a-547151aa1455', 41.297305, -72.787205, NOW())
ON CONFLICT (user_id)
DO UPDATE SET
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    updated_at = EXCLUDED.updated_at;

-- Check the updated locations
SELECT
    'AFTER_UPDATE' as check_type,
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_old
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Calculate distance with new locations
WITH current_locs AS (
    SELECT
        ul.user_id,
        u.name,
        ul.latitude,
        ul.longitude,
        u.match_radius_default
    FROM user_locations ul
    JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
)
SELECT
    'DISTANCE_AFTER_UPDATE' as check_type,
    u1.name as user1_name,
    u2.name as user2_name,
    -- Calculate distance in meters
    (6371000 * 2 * ASIN(SQRT(
        POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
        COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
        POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
    ))) as distance_meters,
    u1.match_radius_default as user1_radius,
    CASE
        WHEN (6371000 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(u2.latitude - u1.latitude) / 2), 2) +
            COS(RADIANS(u1.latitude)) * COS(RADIANS(u2.latitude)) *
            POWER(SIN(RADIANS(u2.longitude - u1.longitude) / 2), 2)
        ))) <= u1.match_radius_default THEN 'WITHIN_RANGE'
        ELSE 'OUT_OF_RANGE'
    END as proximity_status
FROM current_locs u1
CROSS JOIN current_locs u2
WHERE u1.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.user_id = 'ffc20046-a777-463b-922a-547151aa1455';
