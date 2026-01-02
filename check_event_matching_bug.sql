-- Check if the current perform_event_matching function checks shared_event_matching_enabled
-- This will reveal if event matches are being created when they shouldn't be

-- 1. Get the current function source to check if it validates shared_event_matching_enabled
-- Try pg_get_functiondef, fallback to checking pg_proc directly
DO $$
DECLARE
    func_def TEXT;
BEGIN
    BEGIN
        SELECT pg_get_functiondef(oid) INTO func_def
        FROM pg_proc
        WHERE proname = 'perform_event_matching';

        RAISE NOTICE 'Function definition contains shared_event_matching_enabled check: %',
            CASE WHEN func_def LIKE '%shared_event_matching_enabled%' THEN 'YES' ELSE 'NO' END;

        RAISE NOTICE 'Function definition length: % characters', length(func_def);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Could not get function definition: %', SQLERRM;
        RAISE NOTICE 'Checking if function exists at all...';

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'perform_event_matching') THEN
            RAISE NOTICE '✓ Function exists but cannot read source';
        ELSE
            RAISE NOTICE '✗ Function does not exist';
        END IF;
    END;
END $$;

-- 2. Check if the shared_event_matching_enabled column exists in users table
SELECT
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_name = 'users'
AND column_name = 'shared_event_matching_enabled';

-- 3. Check current values for your test users
SELECT
    id,
    email,
    shared_event_matching_enabled,
    COALESCE(user_visibility_setting,false) as user_visibility_setting,
    active_modes
FROM users
WHERE shared_event_matching_enabled IS NOT NULL
ORDER BY updated_at DESC
LIMIT 10;

-- 4. Check recent event matches and which users they involve
SELECT
    m.id as match_id,
    m.match_type,
    m.created_at,
    m.event_id,
    u1.email as user1_email,
    u1.shared_event_matching_enabled as user1_event_matching,
    u2.email as user2_email,
    u2.shared_event_matching_enabled as user2_event_matching,
    e.event_name
FROM matches m
INNER JOIN users u1 ON m.user1_id = u1.id
INNER JOIN users u2 ON m.user2_id = u2.id
LEFT JOIN events e ON m.event_id = e.id
WHERE m.match_type = 'event'
AND m.created_at >= NOW() - INTERVAL '24 hours'
ORDER BY m.created_at DESC;

-- 5. Check if trigger is calling the function
SELECT
    trigger_name,
    event_manipulation,
    event_object_table,
    action_statement,
    action_timing
FROM information_schema.triggers
WHERE event_object_table = 'event_attendees';
