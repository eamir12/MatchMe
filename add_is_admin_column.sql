-- Add is_admin column to users table
-- Run this BEFORE create_app_config_table.sql

-- Add the is_admin column if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_name = 'users' 
        AND column_name = 'is_admin'
    ) THEN
        ALTER TABLE users 
        ADD COLUMN is_admin BOOLEAN DEFAULT false NOT NULL;
        
        -- Add index for performance
        CREATE INDEX IF NOT EXISTS idx_users_is_admin 
        ON users(is_admin) 
        WHERE is_admin = true;
        
        RAISE NOTICE 'Column is_admin added to users table';
    ELSE
        RAISE NOTICE 'Column is_admin already exists';
    END IF;
END $$;

-- Optional: Make specific users admins
-- UPDATE users 
-- SET is_admin = true 
-- WHERE email IN ('your-admin-email@example.com');

-- Verify the column exists
SELECT 
    column_name, 
    data_type, 
    column_default,
    is_nullable
FROM information_schema.columns
WHERE table_name = 'users' 
AND column_name = 'is_admin';
