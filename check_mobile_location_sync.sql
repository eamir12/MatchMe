-- Check if mobile location data is being synced to Supabase

-- 1. Check current location data for both users
SELECT
    ul.user_id,
    u.email,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago,
    CASE
        WHEN EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 < 5 THEN 'RECENT (<5min)'
        WHEN EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 < 30 THEN 'STALE (5-30min)'
        ELSE 'VERY STALE (>30min)'
    END as status
FROM user_locations ul
INNER JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- 2. Check if any proximity matches have been created recently
SELECT
    COUNT(*) as recent_proximity_matches,
    MIN(created_at) as oldest_recent_match,
    MAX(created_at) as newest_recent_match
FROM matches
WHERE match_type = 'proximity'
AND created_at >= NOW() - INTERVAL '1 hour';
