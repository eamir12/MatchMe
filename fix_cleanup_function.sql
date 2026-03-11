-- Fixed cleanup_notification_queue function with correct PostgreSQL syntax
-- This fixes the "column 'sql' does not exist" error

CREATE OR REPLACE FUNCTION cleanup_notification_queue()
RETURNS TABLE(action_taken TEXT, records_affected INTEGER) AS $$
DECLARE
    rows_deleted INTEGER;
    rows_updated INTEGER;
    rows_reset INTEGER;
BEGIN
    -- Clean up NULL user_id records
    DELETE FROM notification_queue 
    WHERE user_id IS NULL;
    
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;
    
    action_taken := 'Deleted records with NULL user_id';
    records_affected := rows_deleted;
    RETURN NEXT;
    
    -- Fix invalid status values
    UPDATE notification_queue 
    SET status = 'pending' 
    WHERE status NOT IN ('pending', 'processing', 'sent', 'failed');
    
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    
    action_taken := 'Fixed invalid status values';
    records_affected := rows_updated;
    RETURN NEXT;
    
    -- Reset stuck 'processing' records back to 'pending'
    UPDATE notification_queue 
    SET status = 'pending',
        updated_at = NOW()
    WHERE status = 'processing' 
    AND updated_at < NOW() - INTERVAL '1 hour'; -- Assume stuck if processing for more than 1 hour
    
    GET DIAGNOSTICS rows_reset = ROW_COUNT;
    
    action_taken := 'Reset stuck processing records';
    records_affected := rows_reset;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Test the fixed function
SELECT '=== TESTING FIXED CLEANUP FUNCTION ===' as step;
SELECT * FROM cleanup_notification_queue();

-- Verify the final state
SELECT '=== FINAL STATE VERIFICATION ===' as step;

SELECT status, COUNT(*) as count 
FROM notification_queue 
GROUP BY status
ORDER BY status;

SELECT 'Fixed cleanup function completed!' as status;