-- Comprehensive fix for notification_queue updated_at column issue
-- This migration ensures the updated_at column exists and is properly configured

-- Step 1: Check if the column exists and add it if it doesn't
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'notification_queue' 
        AND column_name = 'updated_at'
    ) THEN
        ALTER TABLE notification_queue ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
        RAISE NOTICE 'Added updated_at column to notification_queue';
    ELSE
        RAISE NOTICE 'updated_at column already exists in notification_queue';
    END IF;
END $$;

-- Step 2: Check if failure_reason column exists and add it if it doesn't  
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'notification_queue' 
        AND column_name = 'failure_reason'
    ) THEN
        ALTER TABLE notification_queue ADD COLUMN failure_reason TEXT;
        RAISE NOTICE 'Added failure_reason column to notification_queue';
    ELSE
        RAISE NOTICE 'failure_reason column already exists in notification_queue';
    END IF;
END $$;

-- Step 3: Update existing records to have proper updated_at values
UPDATE notification_queue 
SET updated_at = created_at 
WHERE updated_at IS NULL;

-- Step 4: Ensure the column has a default value for future inserts
ALTER TABLE notification_queue 
ALTER COLUMN updated_at SET DEFAULT NOW();

-- Step 5: Create index on updated_at for performance
CREATE INDEX IF NOT EXISTS idx_notification_queue_updated_at ON notification_queue(updated_at);