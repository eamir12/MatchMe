-- Add matching settings columns to users table
-- These columns control event and movement matching features

ALTER TABLE users ADD COLUMN IF NOT EXISTS shared_event_matching_enabled BOOLEAN DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS shared_movement_matching_enabled BOOLEAN DEFAULT false;

-- Add comments for documentation
COMMENT ON COLUMN users.shared_event_matching_enabled IS 'Enables matching with users attending the same events';
COMMENT ON COLUMN users.shared_movement_matching_enabled IS 'Enables matching with users traveling in similar directions and speeds';