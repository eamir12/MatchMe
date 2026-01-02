-- Simple check for Edge and Android user matching issue

-- Check if both users exist and are visible
SELECT
    id,
    name,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    active_modes,
    match_radius_default
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- Check their recent locations
SELECT
    ul.user_id,
    u.name,
    ul.latitude,
    ul.longitude,
    ul.updated_at,
    EXTRACT(EPOCH FROM (NOW() - ul.updated_at)) / 60 as minutes_ago
FROM user_locations ul
JOIN users u ON ul.user_id = u.id
WHERE ul.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
ORDER BY ul.updated_at DESC;

-- Check their interests
SELECT
    up.user_id,
    u.name,
    up.profile_data->'interests' as interests
FROM user_profiles up
JOIN users u ON up.user_id = u.id
WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
AND up.profile_data ? 'interests';

-- Check for existing matches
SELECT
    m.*,
    u1.name as user1_name,
    u2.name as user2_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE (m.user1_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
   AND m.user2_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455'));

-- Check if continuous matching function exists
SELECT proname FROM pg_proc WHERE proname = 'perform_continuous_user_matching';

-- Test the continuous matching function (commented out to avoid creating unwanted matches)
-- SELECT * FROM perform_continuous_user_matching();
