-- Diagnostic to check why locations are stale
-- Shows the exact timestamps and helps identify the location update issue

SELECT
    'LOCATION_FRESHNESS_CHECK' as diagnostic_type,
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_since_update,
    CASE
        WHEN ul.updated_at >= NOW() - INTERVAL '2 minutes' THEN 'VERY_FRESH (<2min)'
        WHEN ul.updated_at >= NOW() - INTERVAL '10 minutes' THEN 'RECENT (2-10min)'
        WHEN ul.updated_at >= NOW() - INTERVAL '30 minutes' THEN 'STALE (10-30min)'
        WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'VERY_STALE (30min-1hr)'
        ELSE 'ANCIENT (>1hr old)'
    END as freshness_status,
    CASE
        WHEN ul.updated_at >= NOW() - INTERVAL '1 hour' THEN 'WITHIN_MATCHING_WINDOW'
        ELSE 'TOO_OLD_FOR_MATCHING'
    END as matching_eligibility
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Show all location records for these users to see the history
SELECT
    'LOCATION_HISTORY' as diagnostic_type,
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    ROW_NUMBER() OVER (PARTITION BY ul.user_id ORDER BY ul.updated_at DESC) as record_number,
    CASE
        WHEN ROW_NUMBER() OVER (PARTITION BY ul.user_id ORDER BY ul.updated_at DESC) = 1 THEN 'MOST_RECENT'
        ELSE 'OLDER_RECORD'
    END as record_type
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.user_id, ul.updated_at DESC;
