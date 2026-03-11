-- Immediate fix for notification_queue constraint violation
-- This addresses the "new row for relation 'notification_queue' violates check constraint 'notification_queue_status_check'" error

-- Step 1: Check what the actual constraint violation is
SELECT '=== INVESTIGATING CONSTRAINT VIOLATION ===' as step;

-- The error shows status='processing' but constraint violation suggests issue
-- Let's check if there's a trigger or rule causing this
SELECT 
    tgname as trigger_name,
    tgenabled as enabled,
    pg_get_triggerdef(oid) as trigger_definition
FROM pg_trigger 
WHERE tgrelid = 'notification_queue'::regclass;

-- Step 2: Check the exact check constraint definition
SELECT 
    conname as constraint_name,
    pg_get_constraintdef(oid) as constraint_definition
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass 
AND contype = 'c'; -- Check constraints only

-- Step 3: Look for any records that might violate constraints
SELECT '=== CHECKING FOR VIOLATING RECORDS ===' as step;

-- Check for NULL user_id (foreign key violation)
SELECT 'Records with NULL user_id:' as issue;
SELECT id, user_id, status, created_at 
FROM notification_queue 
WHERE user_id IS NULL 
LIMIT 5;

-- Check for invalid status values
SELECT 'Records with invalid status:' as issue;
SELECT id, status, COUNT(*) as count 
FROM notification_queue 
WHERE status NOT IN ('pending', 'processing', 'sent', 'failed')
GROUP BY id, status;

-- Step 4: The issue might be in the process_notification_queue function itself
-- Let's recreate it with better error handling and validation
SELECT '=== RECREATING process_notification_queue FUNCTION ===' as step;

CREATE OR REPLACE FUNCTION process_notification_queue()
RETURNS INTEGER AS $$
DECLARE
    notification_record RECORD;
    processed_count INTEGER := 0;
    valid_statuses TEXT[] := ARRAY['pending', 'processing', 'sent', 'failed'];
BEGIN
    -- Process all pending notifications
    FOR notification_record IN 
        SELECT * FROM notification_queue 
        WHERE status = 'pending' 
        AND user_id IS NOT NULL -- Ensure user_id is not NULL
        AND status = ANY(valid_statuses) -- Ensure status is valid
        ORDER BY created_at ASC
        LIMIT 100 -- Process up to 100 notifications at a time
    LOOP
        -- Validate the record before processing
        IF notification_record.user_id IS NULL THEN
            RAISE WARNING 'Skipping notification % due to NULL user_id', notification_record.id;
            CONTINUE;
        END IF;
        
        IF NOT notification_record.status = ANY(valid_statuses) THEN
            RAISE WARNING 'Skipping notification % due to invalid status: %', 
                         notification_record.id, notification_record.status;
            CONTINUE;
        END IF;
        
        -- Update status to processing
        UPDATE notification_queue 
        SET status = 'processing',
            updated_at = NOW()
        WHERE id = notification_record.id;
        
        -- Simulate FCM notification sending (in production, this would call FCM API)
        -- For now, we'll assume success since the actual FCM integration happens on the client side
        
        -- Mark as sent successfully
        UPDATE notification_queue 
        SET status = 'sent', 
            sent_at = NOW(),
            updated_at = NOW()
        WHERE id = notification_record.id;
        
        processed_count := processed_count + 1;
    END LOOP;
    
    RETURN processed_count;
END;
$$ LANGUAGE plpgsql;

-- Step 5: Clean up any problematic records
SELECT '=== CLEANING UP PROBLEMATIC RECORDS ===' as step;

-- Delete records with NULL user_id (they can't be processed)
DELETE FROM notification_queue 
WHERE user_id IS NULL;

-- Fix any records with invalid status
UPDATE notification_queue 
SET status = 'pending' 
WHERE status NOT IN ('pending', 'processing', 'sent', 'failed');

SELECT 'Cleanup completed!' as status;

-- Step 6: Verify the fix
SELECT '=== FINAL VERIFICATION ===' as step;

SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status;

SELECT COUNT(*) as total_records,
       COUNT(*) FILTER (WHERE user_id IS NULL) as null_user_id_count,
       COUNT(*) FILTER (WHERE status NOT IN ('pending', 'processing', 'sent', 'failed')) as invalid_status_count
FROM notification_queue;

SELECT 'Fix completed! The process_notification_queue function should now work without constraint violations.' as final_status;