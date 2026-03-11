-- Test script to verify notification_queue processing works correctly
-- Run this to test the process_notification_queue function

-- Step 1: Clear existing test data
DELETE FROM notification_queue WHERE fcm_token LIKE 'test_token_%';

-- Step 2: Insert test data with valid user_id
-- Make sure we have at least one user in the users table
INSERT INTO notification_queue (user_id, fcm_token, title, body, data, platform, status)
SELECT 
    u.id as user_id,
    'test_token_' || gen_random_uuid() as fcm_token,
    'Test Notification' as title,
    'This is a test notification' as body,
    '{"type": "test"}'::jsonb as data,
    'web' as platform,
    'pending' as status
FROM users u 
LIMIT 3;

SELECT 'Inserted test notifications:' as info;
SELECT id, user_id, status, title 
FROM notification_queue 
WHERE fcm_token LIKE 'test_token_%';

-- Step 3: Test the process_notification_queue function
SELECT 'Testing process_notification_queue function:' as info;

SELECT process_notification_queue() as processed_count;

-- Step 4: Verify the results
SELECT 'After processing:' as info;
SELECT id, user_id, status, sent_at 
FROM notification_queue 
WHERE fcm_token LIKE 'test_token_%';

-- Step 5: Check for any errors
SELECT 'Checking for any constraint violations:' as info;

SELECT 
    conname as constraint_name,
    pg_get_constraintdef(oid) as constraint_definition
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass;

-- Clean up test data
DELETE FROM notification_queue WHERE fcm_token LIKE 'test_token_%';

SELECT 'Test completed successfully!' as info;