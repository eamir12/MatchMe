-- Simple diagnostic to check event matching bug
-- Focus on user settings and recent matches

-- 1. Check if shared_event_matching_enabled column exists
SELECT
    column_name,
    data_type,
    column_default
FROM information_schema.columns
WHERE table_name = 'users'
AND column_name = 'shared_event_matching_enabled';

-- 2. Check your recent event matches and user settings
SELECT
    m.id as match_id,
    m.match_type,
    m.created_at,
    u1.email as user1_email,
    u1.shared_event_matching_enabled as user1_event_enabled,
    u2.email as user2_email,
    u2.shared_event_matching_enabled as user2_event_enabled,
    CASE
        WHEN u1.shared_event_matching_enabled = true AND u2.shared_event_matching_enabled = true THEN 'BOTH_ENABLED'
        WHEN u1.shared_event_matching_enabled = false OR u2.shared_event_matching_enabled = false THEN 'ONE_DISABLED'
        ELSE 'UNKNOWN'
    END as match_legitimacy
FROM matches m
INNER JOIN users u1 ON m.user1_id = u1.id
INNER JOIN users u2 ON m.user2_id = u2.id
WHERE m.match_type = 'event'
ORDER BY m.created_at DESC
LIMIT 5;

-- 3. Check trigger on event_attendees
SELECT
    trigger_name,
    event_manipulation,
    action_statement
FROM information_schema.triggers
WHERE event_object_table = 'event_attendees';

-- 4. Count users by event matching setting
SELECT
    shared_event_matching_enabled,
    COUNT(*) as user_count
FROM users
GROUP BY shared_event_matching_enabled;
