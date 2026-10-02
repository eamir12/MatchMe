-- Location sharing feature configuration
-- Run this in Supabase SQL Editor

INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values)
VALUES
  ('location_sharing.enabled', 'true', 'boolean', 'location_sharing', 'Enable live location sharing between matched users', false, null, null, null),
  ('location_sharing.duration_options_seconds', '[900, 1800, 3600, 7200]', 'array', 'location_sharing', 'Duration picker options in seconds for location sharing (15m, 30m, 1h, 2h)', false, null, null, null),
  ('location_sharing.update_interval_seconds', '5', 'number', 'location_sharing', 'Seconds between location broadcast updates', false, 3, 30, null),
  ('location_sharing.max_duration_seconds', '7200', 'number', 'location_sharing', 'Maximum allowed sharing duration in seconds', false, 300, 14400, null),
  ('location_sharing.inactive_timeout_seconds', '30', 'number', 'location_sharing', 'Seconds before a non-updating peer is shown as stale', false, 10, 120, null)
ON CONFLICT (config_key) DO NOTHING;
