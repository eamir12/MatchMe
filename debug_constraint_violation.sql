-- Debug script to identify the exact constraint violation
-- This will help us understand why 'processing' status is failing the check constraint

-- Step 1: Get the exact constraint definition
SELECT '=== EXACT CONSTRAINT DEFINITION ===' as step;

SELECT 
    conname as constraint_name,
    contype as constraint_type,
    pg_get_constraintdef(oid) as constraint_definition,
    convalidated as is_validated
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass 
AND contype = 'c' -- Check constraints only
AND conname LIKE '%status%';

-- Step 2: Test the constraint manually
SELECT '=== TESTING CONSTRAINT MANUALLY ===' as step;

-- Try to insert a record with 'processing' status manually
-- This should fail if there's really a constraint issue
DO $$
DECLARE
    test_user_id UUID;
    test_result TEXT;
BEGIN
    -- Get a valid user_id
    SELECT id INTO test_user_id FROM users LIMIT 1;
    
    IF test_user_id IS NULL THEN
        RAISE NOTICE 'No users found in the database';
        test_result := 'NO_USERS_FOUND';
    ELSE
        -- Try to insert with 'processing' status
        BEGIN
            INSERT INTO notification_queue (user_id, fcm_token, title, body, status)
            VALUES (test_user_id, 'test_debug_token', 'Debug Test', 'Testing constraint', 'processing');
            
            test_result := 'SUCCESS - processing status is valid';
            
            -- Clean up
            DELETE FROM notification_queue WHERE fcm_token = 'test_debug_token';
            
        EXCEPTION 
            WHEN OTHERS THEN
                test_result := 'FAILED: ' || SQLERRM;
        END;
    END IF;
    
    RAISE NOTICE 'Manual insert test result: %', test_result;
END $$;

-- Step 3: Check for any hidden characters or encoding issues
SELECT '=== CHECKING FOR HIDDEN CHARACTERS ===' as step;

SELECT 
    status,
    length(status) as status_length,
    md5(status) as status_hash,
    ascii(status) as first_char_ascii,
    COUNT(*) as count
FROM notification_queue 
WHERE status IN ('pending', 'processing', 'sent', 'failed')
GROUP BY status
ORDER BY status;

-- Step 4: Check the actual check constraint values
SELECT '=== CHECK CONSTRAINT VALUES ===' as step;

-- This will show us exactly what values are allowed
SELECT 
    pg_get_constraintdef(oid) as constraint_def,
    regexp_matches(pg_get_constraintdef(oid), 'IN \((.*)\)') as allowed_values_match
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass 
AND contype = 'c'
AND conname LIKE '%status%';

-- Step 5: Look for any triggers that might be modifying the status
SELECT '=== CHECKING FOR STATUS-MODIFYING TRIGGERS ===' as step;

SELECT 
    tgname as trigger_name,
    tgenabled as enabled,
    pg_get_triggerdef(oid) as trigger_definition,
    CASE 
        WHEN tgtype & 1 = 1 THEN 'BEFORE'
        WHEN tgtype & 2 = 2 THEN 'AFTER'
        ELSE 'UNKNOWN'
    END as trigger_timing,
    CASE 
        WHEN tgtype & 4 = 4 THEN 'INSERT'
        WHEN tgtype & 8 = 8 THEN 'DELETE'
        WHEN tgtype & 16 = 16 THEN 'UPDATE'
        ELSE 'OTHER'
    END as trigger_event
FROM pg_trigger 
WHERE tgrelid = 'notification_queue'::regclass
ORDER BY tgname;

SELECT 'Debug analysis completed!' as final_step;