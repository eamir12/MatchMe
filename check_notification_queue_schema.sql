-- Test script to verify notification_queue table structure
-- Run this in your Supabase SQL editor to check current table state

-- Check if updated_at column exists
SELECT column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
AND column_name = 'updated_at';

-- Check all columns in notification_queue
SELECT column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
ORDER BY ordinal_position;

-- If updated_at is missing, run this:
-- ALTER TABLE notification_queue ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();
-- ALTER TABLE notification_queue ADD COLUMN IF NOT EXISTS failure_reason TEXT;