-- Check user data
SELECT
    u.id,
    u.active_modes,
    u.shared_event_matching_enabled,
    COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
    (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
      AND COALESCE(u.user_visibility_setting,false) = TRUE
      AND COALESCE(u.system_visibility_status,'visible') = 'visible')::boolean as is_truly_visible,
    jsonb_object_keys(up.profile_data->'interests') as interest_categories,
    up.profile_data->'interests' as interests
FROM users u
LEFT JOIN user_profiles up ON u.id = up.user_id
WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');