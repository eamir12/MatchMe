-- Simulate location update for testing
-- Replace these coordinates with your actual current location
-- Both devices should be at nearly the same coordinates

-- Current approximate location (adjust these to your actual coordinates)
-- For testing: Put both users at the same location
INSERT INTO user_locations (user_id, latitude, longitude, updated_at)
VALUES
    ('35fe114e-eae5-49d6-9eba-8459617e7b82', 41.297300, -72.787200, NOW()),
    ('ffc20046-a777-463b-922a-547151aa1455', 41.297305, -72.787205, NOW())
ON CONFLICT (user_id)
DO UPDATE SET
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    updated_at = EXCLUDED.updated_at;

-- Verify the update worked
SELECT
    'UPDATED_LOCATIONS' as status,
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
