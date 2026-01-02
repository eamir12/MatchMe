-- Check if Edge user is set to invisible, which would explain missing location updates

-- 1. Check visibility settings for both users
SELECT
    id,
    email,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    COALESCE(system_visibility_status,'visible') as system_visibility_status,
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
      AND COALESCE(user_visibility_setting,false) = TRUE
      AND COALESCE(system_visibility_status,'visible') = 'visible')::boolean as is_truly_visible,
    CASE
        WHEN (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
              AND COALESCE(user_visibility_setting,false) = TRUE
              AND COALESCE(system_visibility_status,'visible') = 'visible') THEN 'VISIBLE - should be updating location'
        WHEN COALESCE(user_visibility_setting,false) = false THEN 'INVISIBLE - location updates disabled (manual)'
        ELSE 'INVISIBLE - location updates disabled (system)'
    END as visibility_status
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- 2. Check recent activity vs location updates
WITH user_comparison AS (
    SELECT
        u.id,
        u.email,
        COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
        COALESCE(u.system_visibility_status,'visible') as system_visibility_status,
        MAX(ul.updated_at) as last_location_update,
        MAX(ua.last_activity) as last_activity_update,
        EXTRACT(EPOCH FROM (NOW() - MAX(ul.updated_at))) / 60 as minutes_since_location,
        EXTRACT(EPOCH FROM (NOW() - MAX(ua.last_activity))) / 60 as minutes_since_activity
    FROM users u
    LEFT JOIN user_locations ul ON u.id = ul.user_id
    LEFT JOIN user_activity ua ON u.id = ua.user_id
    WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    GROUP BY u.id, u.email, u.user_visibility_setting, u.system_visibility_status
)
SELECT
    email,
    user_visibility_setting,
    CASE
        WHEN user_visibility_setting = false THEN 'LOCATION DISABLED (invisible)'
        WHEN last_location_update IS NULL THEN 'NO LOCATION DATA'
        WHEN minutes_since_location < 60 THEN 'LOCATION ACTIVE'
        ELSE 'LOCATION STALE (>1hr old)'
    END as location_status,
    CASE
        WHEN minutes_since_activity < 10 THEN 'ACTIVITY ACTIVE'
        ELSE 'ACTIVITY STALE'
    END as activity_status,
    ROUND(minutes_since_location::numeric, 1) as mins_since_location,
    ROUND(minutes_since_activity::numeric, 1) as mins_since_activity
FROM user_comparison;
