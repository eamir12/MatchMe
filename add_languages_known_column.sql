-- Add or modify languages_known column to users table
-- This column stores a JSON object with language codes and their skills

-- First, drop the column if it exists as TEXT[] and recreate as JSONB
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'languages_known' AND data_type = 'ARRAY') THEN
        ALTER TABLE users DROP COLUMN languages_known;
    END IF;
END $$;

ALTER TABLE users ADD COLUMN IF NOT EXISTS languages_known JSONB DEFAULT '{}'::jsonb;

-- Add comment for documentation
COMMENT ON COLUMN users.languages_known IS 'JSON object of languages known with skills (e.g., {"languages": ["en", "es"], "en": ["read", "speak"], "es": ["read"]})';

-- Optional: Create an index for better query performance if needed
-- CREATE INDEX IF NOT EXISTS idx_users_languages_known ON users USING GIN (languages_known);