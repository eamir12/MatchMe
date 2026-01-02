-- Check the MOST RECENT locations for both users (not just within 1 hour)
-- This will show if locations are actually being updated

SELECT
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
    CASE
        WHEN ul.updated_at >= NOW() - INTERVAL '5 minutes' THEN 'VERY_RECENT'
        WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'RECENT'
        ELSE 'OLD'
    END as freshness
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Also check if there are multiple location records (should only be the most recent)
SELECT
    ul.user_id,
    u.name,
    COUNT(*) as total_location_records,
    MAX(ul.updated_at) as latest_update,
    MIN(ul.updated_at) as oldest_update
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
GROUP BY ul.user_id, u.name;
