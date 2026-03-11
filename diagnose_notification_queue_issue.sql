-- Comprehensive diagnostic script for notification_queue constraint violations
-- Run this in your Supabase SQL editor to identify the exact issue

-- Step 1: Check the exact constraint definition
SELECT '=== CONSTRAINT ANALYSIS ===' as analysis_step;

SELECT 
    conname as constraint_name,
    contype as constraint_type,
    pg_get_constraintdef(oid) as constraint_definition,
    CASE 
        WHEN contype = 'c' THEN 'CHECK constraint'
        WHEN contype = 'f' THEN 'FOREIGN KEY constraint'
        WHEN contype = 'p' THEN 'PRIMARY KEY constraint'
        WHEN contype = 'u' THEN 'UNIQUE constraint'
        ELSE 'OTHER'
    END as constraint_type_description
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass
ORDER BY conname;

-- Step 2: Check current table structure
SELECT '=== TABLE STRUCTURE ===' as analysis_step;

SELECT 
    column_name, 
    data_type, 
    is_nullable, 
    column_default,
    CASE 
        WHEN is_nullable = 'NO' THEN 'REQUIRED'
        ELSE 'OPTIONAL'
    END as requirement
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
ORDER BY ordinal_position;

-- Step 3: Check current data distribution
SELECT '=== DATA DISTRIBUTION ===' as analysis_step;

SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status
ORDER BY count DESC;

-- Step 4: Check for problematic data patterns
SELECT '=== PROBLEMATIC DATA PATTERNS ===' as analysis_step;

-- Check for NULL user_id
SELECT 'NULL user_id records:' as issue_type;
SELECT COUNT(*) as count 
FROM notification_queue 
WHERE user_id IS NULL;

-- Check for invalid status values (if any)
SELECT 'Invalid status values:' as issue_type;
SELECT status, COUNT(*) as count 
FROM notification_queue 
WHERE status NOT IN ('pending', 'processing', 'sent', 'failed')
GROUP BY status;

-- Check for recent insert attempts that might be failing
SELECT 'Recent records (last 10):' as analysis_step;
SELECT id, user_id, status, created_at, updated_at 
FROM notification_queue 
ORDER BY created_at DESC 
LIMIT 10;

-- Step 5: Check function definitions
SELECT '=== FUNCTION SIGNATURES ===' as analysis_step;

SELECT 
    proname as function_name,
    pg_get_function_identity_arguments(oid) as function_signature
FROM pg_proc 
WHERE proname IN ('queue_fcm_notification', 'process_notification_queue')
ORDER BY proname;

-- Step 6: Test the queue_fcm_notification function
SELECT '=== FUNCTION TEST ===' as analysis_step;

-- Test with a valid user_id (replace with an actual user_id from your users table)
-- SELECT queue_fcm_notification(
--     (SELECT id FROM users LIMIT 1),
--     'test_token',
--     'Test Title',
--     'Test Body',
--     '{"type": "test"}'::jsonb,
--     'web'
-- );

SELECT 'Diagnostic analysis completed!' as status;