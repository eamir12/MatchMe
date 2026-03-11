-- Add missing updated_at column to notification_queue table
-- This migration fixes the "column 'updated_at' of relation 'notification_queue' does not exist" error

-- Add updated_at column if it doesn't exist
ALTER TABLE notification_queue 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Ensure existing records have updated_at value
UPDATE notification_queue 
SET updated_at = created_at 
WHERE updated_at IS NULL;

-- Add failure_reason column if it doesn't exist
ALTER TABLE notification_queue 
ADD COLUMN IF NOT EXISTS failure_reason TEXT;