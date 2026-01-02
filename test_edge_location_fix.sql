-- Test if Edge location fix is working
-- Check recent location updates for the Edge user

-- 1. Check if Edge user has fresh location data now
SELECT
    'Edge User Location Check' as test_name,
    COUNT(*) as total_location_records,
    MAX(updated_at) as last_location_update,
    EXTRACT(EPOCH FROM (NOW() - MAX(updated_at))) / 60 as minutes_since_last_update,
    CASE
        WHEN MAX(updated_at) > NOW() - INTERVAL '10 minutes' THEN '✅ WORKING - Recent updates'
        WHEN MAX(updated_at) > NOW() - INTERVAL '1 hour' THEN '⚠️ STALE - Updates working but old'
        ELSE '❌ BROKEN - No recent updates'
    END as status
FROM user_locations
WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82';

-- 2. Compare with other user
SELECT
    'Other User Location Check' as test_name,
    COUNT(*) as total_location_records,
    MAX(updated_at) as last_location_update,
    EXTRACT(EPOCH FROM (NOW() - MAX(updated_at))) / 60 as minutes_since_last_update,
    CASE
        WHEN MAX(updated_at) > NOW() - INTERVAL '10 minutes' THEN '✅ WORKING - Recent updates'
        WHEN MAX(updated_at) > NOW() - INTERVAL '1 hour' THEN '⚠️ STALE - Updates working but old'
        ELSE '❌ BROKEN - No recent updates'
    END as status
FROM user_locations
WHERE user_id = 'ffc20046-a777-463b-922a-547151aa1455';

-- 3. Check if new matches are being created (should happen when locations are updated)
SELECT
    'Recent Matches Check' as test_name,
    COUNT(*) as matches_in_last_10min,
    COUNT(*) FILTER (WHERE match_type = 'proximity') as proximity_matches,
    CASE
        WHEN COUNT(*) > 0 THEN '✅ MATCHES CREATED - Location updates working'
        ELSE '❓ NO MATCHES - May be normal if users far apart or no shared interests'
    END as status
FROM matches
WHERE created_at >= NOW() - INTERVAL '10 minutes';
