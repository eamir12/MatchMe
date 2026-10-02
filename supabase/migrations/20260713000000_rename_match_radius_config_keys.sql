-- Rename match-radius app_config keys from misleading `_km` suffix to `_meters`
-- to match the actual unit stored in the DB (the `users.match_radius_default`
-- column is in meters, and all SQL functions divide by 1000 to convert to km).

BEGIN;

-- 1. Rename the options key (rename row if it exists, insert the new key if it doesn't)
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
  SELECT 'profile.match_radius_options_meters', config_value, config_type, category,
         'Allowed match radius options in meters', is_user_configurable, min_value, max_value
  FROM app_config
  WHERE config_key = 'profile.match_radius_options_km';
DELETE FROM app_config WHERE config_key = 'profile.match_radius_options_km';

-- 2. Rename the default key and fix the value (old seed said '20' km; the column is meters)
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
  SELECT 'profile.match_radius_default_meters', '50000', config_type, category,
         'Default match radius for new users (meters)', is_user_configurable, 500, 100000
  FROM app_config
  WHERE config_key = 'profile.match_radius_default_km';
DELETE FROM app_config WHERE config_key = 'profile.match_radius_default_km';

-- 3. If the old rows didn't exist, ensure the new keys are present with correct defaults
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
VALUES ('profile.match_radius_options_meters', '[5, 10, 20, 100]', 'array', 'profile', 'Allowed match radius options in meters', true, null, null)
ON CONFLICT (config_key) DO NOTHING;

INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
VALUES ('profile.match_radius_default_meters', '50000', 'number', 'profile', 'Default match radius for new users (meters)', true, 500, 100000)
ON CONFLICT (config_key) DO NOTHING;

COMMIT;
