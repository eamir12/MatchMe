-- Check user interests for Edge and Android users
SELECT
    up.user_id,
    u.name,
    up.profile_data->'interests' as interests
FROM user_profiles up
JOIN users u ON up.user_id = u.id
WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
AND up.profile_data ? 'interests';
