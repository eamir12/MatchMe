-- ===========================================
-- EVENT MATCHING DIAGNOSTIC QUERIES
-- Run each section separately in Supabase SQL Editor
-- ===========================================

-- QUERY 1: Check user data and event attendance
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT
    u.id as user_id,
    u.active_modes,
    COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
    u.shared_event_matching_enabled,
    up.profile_data->'interests' as interests,
    CASE WHEN ea.user_id IS NOT NULL THEN 'Yes' ELSE 'No' END as attending_event
FROM users u
LEFT JOIN user_profiles up ON u.id = up.user_id
LEFT JOIN event_attendees ea ON u.id = ea.user_id AND ea.event_id = '6497a84c-6ae6-445b-b3e1-e7acc984b2c5'
WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455');

-- ===========================================
-- QUERY 2: Check shared intents
SELECT
    u1.id as user1_id,
    u1.active_modes as user1_intents,
    u2.id as user2_id,
    u2.active_modes as user2_intents,
    CASE
        WHEN u1.active_modes && u2.active_modes THEN 'Yes - Shared intents: ' || array_to_string(u1.active_modes & u2.active_modes, ', ')
        ELSE 'No shared intents'
    END as shared_intents_check
FROM users u1
CROSS JOIN users u2
WHERE u1.id = '35fe114e-eae5-49d6-9eba-8459617e7b82' AND u2.id = 'ffc20046-a777-463b-922a-547151aa1455';

-- ===========================================
-- QUERY 3: Check shared interests
WITH user_interests AS (
    SELECT
        u.id as user_id,
        jsonb_object_keys(up.profile_data->'interests') as category,
        jsonb_array_elements_text(up.profile_data->'interests'->jsonb_object_keys(up.profile_data->'interests')) as interest
    FROM users u
    JOIN user_profiles up ON u.id = up.user_id
    WHERE u.id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
    AND up.profile_data ? 'interests'
)
SELECT
    ui1.user_id as user1_id,
    ui2.user_id as user2_id,
    ui1.category,
    ui1.interest,
    CASE WHEN ui1.interest = ui2.interest THEN 'SHARED' ELSE 'Different' END as match_status
FROM user_interests ui1
JOIN user_interests ui2 ON ui1.category = ui2.category AND ui1.interest = ui2.interest
WHERE ui1.user_id = '35fe114e-eae5-49d6-9eba-8459617e7b82' AND ui2.user_id = 'ffc20046-a777-463b-922a-547151aa1455'
LIMIT 10;

-- ===========================================
-- QUERY 4: Check existing matches
SELECT
    m.id,
    m.user1_id,
    m.user2_id,
    m.match_type,
    m.matched_intent,
    m.event_id,
    m.created_at
FROM matches m
WHERE (m.user1_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455') AND m.user2_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455'))
   OR (m.user1_id IN ('ffc20046-a777-463b-922a-547151aa1455', '35fe114e-eae5-49d6-9eba-8459617e7b82') AND m.user2_id IN ('ffc20046-a777-463b-922a-547151aa1455', '35fe114e-eae5-49d6-9eba-8459617e7b82'));