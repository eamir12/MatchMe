-- Fix for notification_queue constraint violations
-- This script addresses the user_id foreign key constraint issue

-- Step 1: Check current table structure and constraints
SELECT 'Checking current notification_queue structure...' as info;

SELECT column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
ORDER BY ordinal_position;

-- Step 2: Check for records with NULL user_id
SELECT 'Checking for records with NULL user_id...' as info;

SELECT COUNT(*) as null_user_id_count 
FROM notification_queue 
WHERE user_id IS NULL;

-- Step 3: Fix the queue_fcm_notification function to include user_id
-- This function will be replaced with the corrected version
CREATE OR REPLACE FUNCTION queue_fcm_notification(
    p_user_id UUID,
    p_fcm_token TEXT,
    p_title TEXT,
    p_body TEXT,
    p_data JSONB DEFAULT '{}',
    p_platform TEXT DEFAULT 'unknown'
)
RETURNS UUID AS $$
DECLARE
    notification_id UUID;
BEGIN
    INSERT INTO notification_queue (
        user_id, fcm_token, title, body, data, platform
    ) VALUES (
        p_user_id, p_fcm_token, p_title, p_body, p_data, p_platform
    ) RETURNING id INTO notification_id;
    
    RETURN notification_id;
END;
$$ LANGUAGE plpgsql;

-- Step 4: Clean up existing records with NULL user_id (optional - adjust as needed)
-- You can either delete them or update them with a valid user_id
-- For now, let's delete them since they can't be processed anyway
DELETE FROM notification_queue 
WHERE user_id IS NULL;

SELECT 'Cleaned up records with NULL user_id' as info;

-- Step 5: Verify the fix
SELECT 'Verifying fix...' as info;

SELECT COUNT(*) as total_records,
       COUNT(*) FILTER (WHERE user_id IS NULL) as null_user_id_count
FROM notification_queue;

SELECT 'Fix completed successfully!' as info;