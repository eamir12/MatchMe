-- Check recent locations (must be within 1 hour for matching)
SELECT
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
