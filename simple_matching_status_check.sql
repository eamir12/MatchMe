-- MATCHING STATUS CHECK - Run each query separately

-- QUERY 1: Check if continuous user matching function exists
SELECT
    proname as function_name,
    pg_get_function_identity_arguments(oid) as arguments
FROM pg_proc
WHERE proname = 'perform_continuous_user_matching';

-- QUERY 2: Check if there's a trigger on user_locations table
-- Using pg_trigger for more reliable trigger checking
SELECT
    tgname as trigger_name,
    tgtype as trigger_type,
    tgenabled as enabled,
    obj_description(t.oid, 'pg_trigger') as description
FROM pg_trigger t
JOIN pg_class c ON t.tgrelid = c.oid
WHERE c.relname = 'user_locations';

-- Alternative: Check information_schema if pg_trigger doesn't work
SELECT
    trigger_catalog,
    trigger_schema,
    trigger_name,
    event_manipulation,
    event_object_table,
    action_statement
FROM information_schema.triggers
WHERE event_object_table = 'user_locations';

-- QUERY 3: Check function permissions
SELECT
    grantee,
    privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = 'perform_continuous_user_matching';

-- QUERY 4: Check recent matches (last 24 hours)
SELECT
    COUNT(*) as matches_last_24h,
    COUNT(*) FILTER (WHERE match_type = 'proximity') as proximity_matches,
    COUNT(*) FILTER (WHERE match_type = 'event') as event_matches
FROM matches
WHERE created_at >= NOW() - INTERVAL '24 hours';

-- QUERY 5: Check if users are visible and have recent locations
SELECT
    COUNT(*) as visible_users_with_recent_locations
FROM user_locations ul
INNER JOIN users u ON ul.user_id = u.id
WHERE public.is_user_truly_visible(u.id) = TRUE
AND ul.updated_at >= NOW() - INTERVAL '1 hour';

-- QUERY 6: Check table counts
SELECT
    'user_locations' as table_name,
    COUNT(*) as record_count
FROM user_locations
UNION ALL
SELECT
    'matches' as table_name,
    COUNT(*) as record_count
FROM matches;
