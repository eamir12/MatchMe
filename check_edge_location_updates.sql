-- Check if Edge user location is being updated at all

SELECT
    'Edge User (35fe114e-eae5-49d6-9eba-8459617e7b82)' as user_type,
    COUNT(*) as location_records,
    MAX(updated_at) as last_location_update,
    EXTRACT(EPOCH FROM (NOW() - MAX(updated_at))) / 60 as minutes_since_last_location
FROM user_locations
WHERE user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'

UNION ALL

SELECT
    'Other User (ffc20046-a777-463b-922a-547151aa1455)' as user_type,
    COUNT(*) as location_records,
    MAX(updated_at) as last_location_update,
    EXTRACT(EPOCH FROM (NOW() - MAX(updated_at))) / 60 as minutes_since_last_location
FROM user_locations
WHERE user_id = 'ffc20046-a777-463b-922a-547151aa1455'

UNION ALL

SELECT
    'All Users' as user_type,
    COUNT(*) as location_records,
    MAX(updated_at) as last_location_update,
    NULL as minutes_since_last_location
FROM user_locations;
