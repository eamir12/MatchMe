-- Diagnostic script to check all constraints on notification_queue table
-- Run this in your Supabase SQL editor to identify the constraint violation

-- Check all constraints on notification_queue
SELECT 
    conname as constraint_name,
    contype as constraint_type,
    consrc as constraint_definition,
    consrc as check_condition
FROM pg_constraint 
WHERE conrelid = 'notification_queue'::regclass
ORDER BY conname;

-- Check the exact table structure
SELECT column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
ORDER BY ordinal_position;

-- Check if user_id column has NOT NULL constraint
SELECT 
    column_name,
    is_nullable,
    column_default
FROM information_schema.columns 
WHERE table_name = 'notification_queue' 
AND column_name = 'user_id';