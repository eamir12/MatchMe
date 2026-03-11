-- Immediate fix for "column 'updated_at' of relation 'notification_queue' does not exist"
-- Copy and paste this into your Supabase SQL editor and run it

-- Check current table structure first
SELECT 'Current notification_queue columns:' as info;
SELECT column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
ORDER BY ordinal_position;

-- Add missing columns
SELECT 'Adding missing columns...' as info;

-- Add updated_at column if missing
ALTER TABLE notification_queue 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Add failure_reason column if missing  
ALTER TABLE notification_queue 
ADD COLUMN IF NOT EXISTS failure_reason TEXT;

-- Update existing records
UPDATE notification_queue 
SET updated_at = created_at 
WHERE updated_at IS NULL;

-- Verify the fix
SELECT 'Updated notification_queue columns:' as info;
SELECT column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
ORDER BY ordinal_position;

SELECT 'Fix completed successfully!' as info;