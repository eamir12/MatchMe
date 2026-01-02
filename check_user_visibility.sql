-- Check user visibility and intents for Edge and Android users
SELECT
    id,
    name,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    active_modes,
    match_radius_default
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');
