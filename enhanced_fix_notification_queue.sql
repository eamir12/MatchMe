-- Enhanced fix for notification_queue processing with better error handling
-- This version handles edge cases and prevents constraint violations

-- Create a more robust version of process_notification_queue
CREATE OR REPLACE FUNCTION process_notification_queue()
RETURNS INTEGER AS $$
DECLARE
    notification_record RECORD;
    processed_count INTEGER := 0;
    valid_statuses TEXT[] := ARRAY['pending', 'processing', 'sent', 'failed'];
    current_status TEXT;
BEGIN
    -- Process all pending notifications
    FOR notification_record IN 
        SELECT * FROM notification_queue 
        WHERE status = 'pending' 
        AND user_id IS NOT NULL -- Ensure user_id is not NULL
        ORDER BY created_at ASC
        LIMIT 100 -- Process up to 100 notifications at a time
    LOOP
        -- Double-check the current status (in case it changed)
        SELECT status INTO current_status 
        FROM notification_queue 
        WHERE id = notification_record.id 
        FOR UPDATE;
        
        -- Skip if status is no longer 'pending'
        IF current_status != 'pending' THEN
            RAISE NOTICE 'Skipping notification % - status changed from pending to %', 
                        notification_record.id, current_status;
            CONTINUE;
        END IF;
        
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
        
        -- Update status to processing with explicit validation
        UPDATE notification_queue 
        SET status = 'processing',
            updated_at = NOW()
        WHERE id = notification_record.id 
        AND status = 'pending'; -- Ensure we only update if still pending
        
        -- Check if the update was successful
        IF NOT FOUND THEN
            RAISE NOTICE 'Could not update notification % - may have been processed by another session', 
                        notification_record.id;
            CONTINUE;
        END IF;
        
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

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION process_notification_queue() TO authenticated;
GRANT EXECUTE ON FUNCTION process_notification_queue() TO service_role;

-- Create a function to safely clean up problematic records
CREATE OR REPLACE FUNCTION cleanup_notification_queue()
RETURNS TABLE(action_taken TEXT, records_affected INTEGER) AS $$
BEGIN
    -- Clean up NULL user_id records
    DELETE FROM notification_queue 
    WHERE user_id IS NULL;
    
    action_taken := 'Deleted records with NULL user_id';
    records_affected := COALESCE(sql%rowcount, 0);
    RETURN NEXT;
    
    -- Fix invalid status values
    UPDATE notification_queue 
    SET status = 'pending' 
    WHERE status NOT IN ('pending', 'processing', 'sent', 'failed');
    
    action_taken := 'Fixed invalid status values';
    records_affected := COALESCE(sql%rowcount, 0);
    RETURN NEXT;
    
    -- Reset stuck 'processing' records back to 'pending'
    UPDATE notification_queue 
    SET status = 'pending',
        updated_at = NOW()
    WHERE status = 'processing' 
    AND updated_at < NOW() - INTERVAL '1 hour'; -- Assume stuck if processing for more than 1 hour
    
    action_taken := 'Reset stuck processing records';
    records_affected := COALESCE(sql%rowcount, 0);
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Run the cleanup
SELECT '=== RUNNING CLEANUP ===' as step;
SELECT * FROM cleanup_notification_queue();

-- Verify the final state
SELECT '=== FINAL STATE VERIFICATION ===' as step;

SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status
ORDER BY status;

SELECT 'Enhanced fix completed!' as status;