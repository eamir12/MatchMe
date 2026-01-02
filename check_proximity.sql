-- Check proximity between Edge and Android users
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
)
SELECT
    u1.user_id as user1_id,
    u1.name as user1_name,
    u2.user_id as user2_id,
    u2.name as user2_name,
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
WHERE u1.user_id < u2.user_id;
