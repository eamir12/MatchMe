-- Add lifestyle, family, religion, height, occupation, and education columns to users table
-- Also add per-intent filter columns for each new filter domain

-- Simple scalar columns
ALTER TABLE users ADD COLUMN IF NOT EXISTS height INTEGER DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS occupation TEXT DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS education TEXT DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS zodiac_sign TEXT DEFAULT NULL;

-- JSONB compound columns (grouping related attributes)
ALTER TABLE users ADD COLUMN IF NOT EXISTS lifestyle JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS family JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS religion JSONB DEFAULT NULL;

-- Per-intent filter columns (mirrors gender_preferences pattern)
ALTER TABLE users ADD COLUMN IF NOT EXISTS lifestyle_filters JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS family_filters JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS religion_filters JSONB DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS height_preferences JSONB DEFAULT NULL;

-- Add comments for documentation
COMMENT ON COLUMN users.height IS 'User height in centimeters';
COMMENT ON COLUMN users.occupation IS 'Job title or occupation';
COMMENT ON COLUMN users.education IS 'Highest education level';
COMMENT ON COLUMN users.zodiac_sign IS 'Astrological zodiac sign (auto-calculated from date_of_birth)';
COMMENT ON COLUMN users.lifestyle IS 'JSON object: { smoking, drinking, exercise, diet }';
COMMENT ON COLUMN users.family IS 'JSON object: { has_children, wants_children }';
COMMENT ON COLUMN users.religion IS 'JSON object: { religion, importance }';
COMMENT ON COLUMN users.lifestyle_filters IS 'Per-intent lifestyle filter preferences';
COMMENT ON COLUMN users.family_filters IS 'Per-intent family filter preferences, keyed by intent';
COMMENT ON COLUMN users.religion_filters IS 'Per-intent religion filter preferences, keyed by intent';
COMMENT ON COLUMN users.height_preferences IS 'Per-intent height range preferences, keyed by intent';
