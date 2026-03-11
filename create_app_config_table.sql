-- Create app_config table for centralized application settings
-- This table stores both system-wide configs and default values for user-configurable settings

-- STEP 1: Ensure users table has is_admin column
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
        
        CREATE INDEX IF NOT EXISTS idx_users_is_admin 
        ON users(is_admin) 
        WHERE is_admin = true;
        
        RAISE NOTICE 'Column is_admin added to users table';
    END IF;
END $$;

-- STEP 2: Create app_config table
CREATE TABLE IF NOT EXISTS app_config (
    id SERIAL PRIMARY KEY,
    config_key VARCHAR(100) UNIQUE NOT NULL,
    config_value JSONB NOT NULL,
    config_type VARCHAR(50) NOT NULL, -- 'number', 'duration_seconds', 'boolean', 'array', 'string', 'percentage'
    category VARCHAR(50) NOT NULL, -- 'gps', 'sync', 'cache', 'notification', 'ui', 'profile', 'calendar', 'translation'
    description TEXT NOT NULL,
    is_user_configurable BOOLEAN DEFAULT FALSE,
    min_value NUMERIC, -- for validation (optional)
    max_value NUMERIC, -- for validation (optional)
    allowed_values JSONB, -- for enum-like values (optional) e.g., [5, 10, 20, 30, 60]
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_app_config_key ON app_config(config_key);
CREATE INDEX IF NOT EXISTS idx_app_config_category ON app_config(category);
CREATE INDEX IF NOT EXISTS idx_app_config_user_configurable ON app_config(is_user_configurable);

-- Create updated_at trigger
CREATE OR REPLACE FUNCTION update_app_config_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop trigger if it exists before creating
DROP TRIGGER IF EXISTS trigger_app_config_updated_at ON app_config;

CREATE TRIGGER trigger_app_config_updated_at
    BEFORE UPDATE ON app_config
    FOR EACH ROW
    EXECUTE FUNCTION update_app_config_updated_at();

-- Enable RLS
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Anyone can read app_config" ON app_config;
DROP POLICY IF EXISTS "Only admins can insert app_config" ON app_config;
DROP POLICY IF EXISTS "Only admins can update app_config" ON app_config;
DROP POLICY IF EXISTS "Only admins can delete app_config" ON app_config;

-- Policies: Everyone can read, only admins can modify
CREATE POLICY "Anyone can read app_config"
    ON app_config FOR SELECT
    TO authenticated, anon
    USING (true);

CREATE POLICY "Only admins can insert app_config"
    ON app_config FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = auth.uid()
            AND users.is_admin = true
        )
    );

CREATE POLICY "Only admins can update app_config"
    ON app_config FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = auth.uid()
            AND users.is_admin = true
        )
    );

CREATE POLICY "Only admins can delete app_config"
    ON app_config FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM users
            WHERE users.id = auth.uid()
            AND users.is_admin = true
        )
    );

-- Insert initial configuration values based on the HIGH PRIORITY settings
-- Use ON CONFLICT to make this migration idempotent (safe to run multiple times)
-- GPS & Location Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('gps.battery_low_threshold_percent', '15', 'percentage', 'gps', 'Battery percentage threshold to trigger GPS throttling (when Smart GPS is enabled)', false, 5, 30),
('gps.battery_throttle_interval_seconds', '60', 'duration_seconds', 'gps', 'GPS update interval when battery is low and not charging (only when Smart GPS enabled)', false, 30, 300),
('gps.stationary_max_positions', '5', 'number', 'gps', 'Number of recent positions to track for stationary detection', false, 3, 10),
('gps.stationary_similarity_threshold_meters', '10.0', 'number', 'gps', 'Distance threshold in meters to consider positions as similar (stationary)', false, 5, 50),
('gps.stationary_movement_threshold_meters', '10.0', 'number', 'gps', 'Minimum movement in meters to be considered as moving', false, 5, 50),
('gps.stationary_throttle_interval_seconds', '60', 'duration_seconds', 'gps', 'GPS update interval when user is stationary (Smart GPS throttling)', false, 30, 300),
('gps.web_hidden_throttle_seconds', '60', 'duration_seconds', 'gps', 'Minimum GPS interval when browser tab is hidden (web only, when Smart GPS enabled)', false, 30, 300),
('gps.web_max_acceptable_accuracy_meters', '1500.0', 'number', 'gps', 'Maximum acceptable location accuracy for web browsers (1.5km)', false, 500, 5000),
('gps.web_preferred_accuracy_meters', '200.0', 'number', 'gps', 'Preferred location accuracy for web browsers', false, 50, 1000),
('gps.web_sample_max_accuracy_meters', '50.0', 'number', 'gps', 'Maximum accuracy for web location sampling', false, 20, 200),
('gps.mobile_time_limit_seconds', '15', 'duration_seconds', 'gps', 'Time limit for mobile GPS location acquisition', false, 5, 60),
('gps.interval_options_seconds', '[5, 10, 20, 30, 60]', 'array', 'gps', 'Allowed GPS update interval options for users', true, null, null),
('gps.interval_default_seconds', '5', 'duration_seconds', 'gps', 'Default GPS update interval for new users', true, 5, 60),
('gps.kalman_process_noise_position', '0.0001', 'number', 'gps', 'Kalman filter position variance per second', false, 0.00001, 0.001),
('gps.kalman_process_noise_velocity', '0.001', 'number', 'gps', 'Kalman filter velocity variance per second', false, 0.0001, 0.01),
('gps.kalman_min_accuracy_meters', '5.0', 'number', 'gps', 'Kalman filter minimum accuracy to use', false, 1, 20),
('gps.kalman_max_accuracy_meters', '200.0', 'number', 'gps', 'Kalman filter maximum accuracy to use', false, 50, 1000)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value;

-- Sync & Update Intervals
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('sync.global_interval_seconds', '60', 'duration_seconds', 'sync', 'How often to sync matches and chats from server', false, 30, 300),
('sync.heartbeat_interval_seconds', '20', 'duration_seconds', 'sync', 'How often to update user activity to keep online status fresh', false, 10, 60),
('sync.outbox_retry_interval_seconds', '5', 'duration_seconds', 'sync', 'How often to retry sending failed messages from outbox', false, 3, 30),
('sync.recent_items_limit', '5', 'number', 'sync', 'Number of recent chats/matches to fetch during sync', false, 3, 20),
('matches.chat_start_window_seconds', '86400', 'duration_seconds', 'sync', 'How long a match lasts unless a chat message is sent', false, 60, 604800)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value;

-- Cache Duration Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('cache.profile_duration_seconds', '300', 'duration_seconds', 'cache', 'How long to cache user profile data (5 minutes)', false, 60, 3600),
('cache.visibility_duration_seconds', '1800', 'duration_seconds', 'cache', 'How long to cache user visibility data (30 minutes)', false, 300, 7200),
('cache.rules_duration_seconds', '3600', 'duration_seconds', 'cache', 'How long to cache invisibility rules (1 hour)', false, 600, 14400),
('cache.user_details_duration_seconds', '900', 'duration_seconds', 'cache', 'How long to cache user detail data (15 minutes)', false, 300, 3600),
('cache.events_duration_seconds', '300', 'duration_seconds', 'cache', 'How long to cache user events (5 minutes)', false, 60, 1800)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value;

-- Calendar Sync Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('calendar.token_refresh_buffer_seconds', '300', 'duration_seconds', 'calendar', 'Refresh OAuth tokens this many seconds before expiry (5 minutes)', false, 60, 600),
('calendar.default_token_expiry_seconds', '3600', 'duration_seconds', 'calendar', 'Default token expiry time if not provided (1 hour)', false, 1800, 7200),
('calendar.fetch_range_days', '30', 'number', 'calendar', 'How many days forward to fetch calendar events', false, 7, 90),
('calendar.api_timeout_seconds', '30', 'duration_seconds', 'calendar', 'Timeout for calendar API requests', false, 10, 120),
('calendar.google_max_results', '250', 'number', 'calendar', 'Maximum results per page for Google Calendar API', false, 50, 250)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- Notification & UI Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('notification.match_auto_dismiss_seconds', '5', 'duration_seconds', 'notification', 'Auto-dismiss match notifications after this many seconds', true, 3, 30),
('notification.system_auto_dismiss_seconds', '6', 'duration_seconds', 'notification', 'Auto-dismiss system notifications after this many seconds', true, 3, 30),
('notification.web_delay_seconds', '15', 'duration_seconds', 'notification', 'Delay before showing web notifications', false, 5, 60),
('notification.permission_prompt_min_interval_seconds', '15', 'duration_seconds', 'notification', 'Minimum time between permission prompts', false, 10, 120),
('notification.mute_quick_durations_seconds', '[300, 900, 1800, 3600, 28800]', 'array', 'notification', 'Quick mute durations shown in notification settings (seconds)', true, null, null),
('matches.chat_start_expiry_warning_seconds', '[3600, 300, 60]', 'array', 'notification', 'When to warn about match chat-start expiry (seconds before expiry)', false, null, null)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- App Behavior Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('ui.app_state_debounce_ms', '500', 'number', 'ui', 'Debounce duration for app state changes (milliseconds)', false, 100, 2000),
('ui.throttling_debounce_seconds', '3', 'duration_seconds', 'ui', 'Debounce duration for GPS throttling changes', false, 1, 10),
('ui.log_throttle_ms', '1000', 'number', 'ui', 'Minimum interval between repeated log messages (milliseconds)', false, 500, 5000),
('ui.translation_fetch_delay_ms', '1500', 'number', 'ui', 'Delay for stale-while-revalidate translation fetching (milliseconds)', false, 500, 5000),
('ui.home_initial_delay_ms', '200', 'number', 'ui', 'Initial delay for home provider loading (milliseconds)', false, 0, 1000),
('ui.home_refresh_delay_ms', '100', 'number', 'ui', 'Refresh delay for home provider (milliseconds)', false, 0, 500),
('ui.home_revalidation_seconds', '2', 'duration_seconds', 'ui', 'Revalidation delay for home provider', false, 1, 10)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- Translation Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('translation.deepl_monthly_limit_chars', '500000', 'number', 'translation', 'DeepL API free tier monthly character limit', false, 100000, 1000000),
('translation.language_detection_confidence', '0.5', 'number', 'translation', 'Confidence threshold for language identification (0-1)', false, 0.3, 0.9)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- Profile & User Settings
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('profile.match_radius_options_km', '[5, 10, 20, 100]', 'array', 'profile', 'Allowed match radius options in kilometers', true, null, null),
('profile.match_radius_default_km', '20', 'number', 'profile', 'Default match radius for new users (kilometers)', true, 5, 100),
('profile.age_range_min', '18', 'number', 'profile', 'Minimum age allowed for users', false, 18, 21),
('profile.age_range_max', '100', 'number', 'profile', 'Maximum age allowed for users', false, 80, 120),
('profile.age_preference_default_min', '18', 'number', 'profile', 'Default minimum age preference for new users', true, 18, 100),
('profile.age_preference_default_max', '100', 'number', 'profile', 'Default maximum age preference for new users', true, 18, 100),
('profile.image_quality_percent', '90', 'percentage', 'profile', 'JPEG quality when picking/uploading photos', false, 70, 100),
('profile.max_file_size_bytes', '5242880', 'number', 'profile', 'Maximum file size for photo uploads (5MB in bytes)', false, 1048576, 10485760),
('profile.signed_url_ttl_seconds', '3600', 'duration_seconds', 'profile', 'Time-to-live for signed photo URLs (1 hour)', false, 300, 86400),
('profile.signed_url_short_ttl_seconds', '600', 'duration_seconds', 'profile', 'Short time-to-live for signed URLs (10 minutes)', false, 300, 3600),
('profile.bio_max_length', '300', 'number', 'profile', 'Maximum character length for user bio', false, 100, 1000)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

-- Time of Day Ranges (for invisibility rules, matching preferences, etc.)
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('time_ranges.morning_start_hour', '4', 'number', 'ui', 'Hour when morning period starts (24h format)', false, 0, 12),
('time_ranges.morning_end_hour', '11', 'number', 'ui', 'Hour when morning period ends (24h format)', false, 0, 23),
('time_ranges.afternoon_start_hour', '12', 'number', 'ui', 'Hour when afternoon period starts (24h format)', false, 0, 23),
('time_ranges.afternoon_end_hour', '17', 'number', 'ui', 'Hour when afternoon period ends (24h format)', false, 0, 23),
('time_ranges.evening_start_hour', '18', 'number', 'ui', 'Hour when evening period starts (24h format)', false, 0, 23),
('time_ranges.evening_end_hour', '21', 'number', 'ui', 'Hour when evening period ends (24h format)', false, 0, 23)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value;

-- Performance & Optimization
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('performance.web_location_sample_interval_seconds', '2', 'duration_seconds', 'gps', 'Interval for web location sampling', false, 1, 10),
('performance.mobile_location_restart_delay_ms', '200', 'number', 'gps', 'Delay before restarting mobile location service (milliseconds)', false, 100, 1000),
('performance.missing_keys_display_limit', '20', 'number', 'ui', 'Maximum number of missing translation keys to display in logs', false, 10, 100)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value;

-- Comment explaining the schema
COMMENT ON TABLE app_config IS 'Central configuration table for all app settings. Stores both system-wide configs and default values for user-configurable settings. User-specific overrides are stored in the users table.';
COMMENT ON COLUMN app_config.config_key IS 'Unique identifier for the configuration setting, using dot notation (e.g., gps.battery_low_threshold_percent)';
COMMENT ON COLUMN app_config.config_value IS 'The configuration value stored as JSONB for flexibility. Parse according to config_type.';
COMMENT ON COLUMN app_config.config_type IS 'Data type of the value: number, duration_seconds, boolean, array, string, percentage';
COMMENT ON COLUMN app_config.category IS 'Category grouping: gps, sync, cache, notification, ui, profile, calendar, translation, performance';
COMMENT ON COLUMN app_config.is_user_configurable IS 'If true, users can override this setting in their profile. If false, only admins can change it.';
COMMENT ON COLUMN app_config.allowed_values IS 'Optional JSONB array of allowed values for validation (e.g., [5, 10, 20, 30, 60])';
