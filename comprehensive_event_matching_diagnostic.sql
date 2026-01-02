-- ===========================================
-- COMPREHENSIVE EVENT MATCHING DIAGNOSTIC
-- IMPORTANT: Run each QUERY section separately in Supabase SQL Editor
-- Supabase doesn't support multiple statements in one execution
-- ===========================================

-- QUERY 1: Check if the perform_event_matching function exists and is up to date
SELECT
    proname,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description
FROM pg_proc
WHERE proname = 'perform_event_matching';

-- ===========================================
-- QUERY 2: Check if the trigger exists
SELECT
    trigger_name,
    event_manipulation,
    event_object_table,
    action_statement
FROM information_schema.triggers
WHERE trigger_name = 'trigger_event_matching';

-- ===========================================
-- QUERY 3: Check user data
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

-- ===========================================
-- QUERY 4: Find events both users are attending
SELECT
    ea.event_id,
    e.event_name,
    e.start_time,
    COUNT(*) as total_attendees
FROM event_attendees ea
JOIN events e ON ea.event_id = e.id
WHERE ea.user_id IN ('35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455')
GROUP BY ea.event_id, e.event_name, e.start_time
HAVING COUNT(*) = 2 -- Both users attending
ORDER BY e.start_time DESC;

-- ===========================================
-- QUERY 5: Check event attendance for a specific event
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT
    ea.user_id,
    u.active_modes,
    u.shared_event_matching_enabled
FROM event_attendees ea
JOIN users u ON ea.user_id = u.id
WHERE ea.event_id = '6497a84c-6ae6-445b-b3e1-e7acc984b2c5';

-- ===========================================
-- QUERY 6: Test the function manually
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT perform_event_matching('6497a84c-6ae6-445b-b3e1-e7acc984b2c5');

-- ===========================================
-- QUERY 7: Check for newly created matches
-- Using the event ID from your data: 6497a84c-6ae6-445b-b3e1-e7acc984b2c5
SELECT
    m.*,
    u1.name as user_a_name,
    u2.name as user_b_name
FROM matches m
JOIN users u1 ON m.user1_id = u1.id
JOIN users u2 ON m.user2_id = u2.id
WHERE m.event_id = '6497a84c-6ae6-445b-b3e1-e7acc984b2c5'
ORDER BY m.created_at DESC
LIMIT 10;