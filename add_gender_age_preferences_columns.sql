-- Add gender and age preferences columns to users table
-- These columns store user preferences for matching based on gender and age per intent

ALTER TABLE users ADD COLUMN IF NOT EXISTS gender_preferences JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS age_preferences JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS strict_gender_age_enforcement BOOLEAN DEFAULT false;

-- Add comments for documentation
COMMENT ON COLUMN users.gender_preferences IS 'JSON object mapping intent keys to lists of preferred gender keys';
COMMENT ON COLUMN users.age_preferences IS 'JSON object mapping intent keys to age range arrays [min, max]';
COMMENT ON COLUMN users.strict_gender_age_enforcement IS 'Whether to strictly enforce gender/age preferences or just prioritize them';