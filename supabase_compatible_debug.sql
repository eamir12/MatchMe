-- Supabase-compatible debug query for Edge/Android matching issue
-- Run each section separately in Supabase SQL Editor

-- SECTION 1: Check user visibility and intents
SELECT
    'USER_VISIBILITY' as check_type,
    id,
    name,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    COALESCE(system_visibility_status,'visible') as system_visibility_status,
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
      AND COALESCE(user_visibility_setting,false) = TRUE
      AND COALESCE(system_visibility_status,'visible') = 'visible')::boolean as is_truly_visible,
    active_modes,
    match_radius_default
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');
