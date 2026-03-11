-- Immediate fix for notification_queue constraint violations
-- Copy and paste this into your Supabase SQL editor and run it

-- Step 1: Check what constraints are being violated
SELECT 'Checking constraints on notification_queue...' as info;

SELECT 
    conname as constraint_name,
    contype as constraint_type,
    pg_get_constraintdef(oid) as constraint_definition
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass
ORDER BY conname;

-- Step 2: Check current data that might be causing issues
SELECT 'Checking problematic records...' as info;

SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status;

-- Step 3: Fix any records with invalid status values
UPDATE notification_queue 
SET status = 'pending' 
WHERE status NOT IN ('pending', 'processing', 'sent', 'failed');

-- Step 4: Check for NULL user_id issues
SELECT 'Checking for NULL user_id...' as info;

SELECT COUNT(*) as null_user_id_count 
FROM notification_queue 
WHERE user_id IS NULL;

-- Step 5: Clean up or fix NULL user_id records
-- Option A: Delete them (they can't be processed anyway)
DELETE FROM notification_queue 
WHERE user_id IS NULL;

-- Option B: If you want to keep them, update with a valid user_id
-- UPDATE notification_queue 
-- SET user_id = (SELECT id FROM users LIMIT 1)  -- Replace with appropriate user_id
-- WHERE user_id IS NULL;

SELECT 'Cleanup completed!' as info;

-- Step 6: Verify the fix
SELECT 'Final verification:' as info;

SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status;

SELECT COUNT(*) as total_records,
       COUNT(*) FILTER (WHERE user_id IS NULL) as null_user_id_count
FROM notification_queue;

SELECT 'Fix completed successfully!' as info;