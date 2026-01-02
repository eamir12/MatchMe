-- Check shared intents and interests - the likely blockers

-- 1. Check if both users have active intents
SELECT
    'ACTIVE MODES CHECK' as check_type,
    id,
    name,
    active_modes,
    CASE
        WHEN active_modes IS NULL THEN 'NULL - WILL SKIP'
        WHEN array_length(active_modes, 1) = 0 THEN 'EMPTY - WILL SKIP'
        ELSE 'HAS INTENTS'
    END as intent_status
FROM users
WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- 2. Check shared intents specifically
WITH user_intents AS (
    SELECT
        id,
        name,
        active_modes
    FROM users
    WHERE id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
)
SELECT
    'SHARED INTENTS DETAIL' as check_type,
    u1.name as user1_name,
    u1.active_modes as user1_intents,
    u2.name as user2_name,
    u2.active_modes as user2_intents,
    CASE
        WHEN u1.active_modes IS NULL OR u2.active_modes IS NULL THEN 'NULL_INTENTS'
        WHEN NOT (u1.active_modes && u2.active_modes) THEN 'NO_OVERLAP'
        ELSE 'HAS_SHARED_INTENTS'
    END as shared_status,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN
            ARRAY(SELECT unnest(u1.active_modes) INTERSECT SELECT unnest(u2.active_modes))
        ELSE NULL
    END as shared_intents
FROM user_intents u1
CROSS JOIN user_intents u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455';

-- 3. Check interests structure
SELECT
    'INTERESTS STRUCTURE' as check_type,
    u.name,
    up.profile_data->'interests' as interests_json,
    CASE
        WHEN up.profile_data->'interests' IS NULL THEN 'NO_INTERESTS_DATA'
        WHEN jsonb_typeof(up.profile_data->'interests') = 'object' THEN 'HAS_INTERESTS_OBJECT'
        ELSE 'INVALID_FORMAT'
    END as interests_status
FROM user_profiles up
JOIN users u ON up.user_id = u.id
WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
AND up.profile_data ? 'interests';

-- 4. Check shared interests by category
WITH user_interests AS (
    SELECT
        u.name,
        up.user_id,
        up.profile_data->'interests' as interests
    FROM user_profiles up
    JOIN users u ON up.user_id = u.id
    WHERE up.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    AND up.profile_data ? 'interests'
),
interest_comparison AS (
    SELECT
        ui1.name as user1_name,
        ui1.interests as user1_interests,
        ui2.name as user2_name,
        ui2.interests as user2_interests,
        -- Check if any category has shared interests
        EXISTS (
            SELECT 1
            FROM jsonb_object_keys(ui1.interests) cat
            WHERE ui1.interests ? cat
            AND ui2.interests ? cat
            AND jsonb_array_length(ui1.interests->cat) > 0
            AND jsonb_array_length(ui2.interests->cat) > 0
            AND EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(ui1.interests->cat) i1
                WHERE i1 IN (SELECT jsonb_array_elements_text(ui2.interests->cat))
            )
        ) as has_shared_interests
    FROM user_interests ui1
    CROSS JOIN user_interests ui2
    WHERE ui1.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82'
    AND ui2.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
)
SELECT
    'SHARED INTERESTS RESULT' as check_type,
    user1_name,
    user2_name,
    has_shared_interests,
    CASE
        WHEN has_shared_interests THEN 'INTERESTS_MATCH'
        ELSE 'NO_SHARED_INTERESTS'
    END as interests_status
FROM interest_comparison;
