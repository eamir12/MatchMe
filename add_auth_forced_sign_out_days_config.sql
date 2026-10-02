-- Add forced sign-out days configuration to app_config
-- When set, the app will force users to re-authenticate after N days

INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
VALUES (
  'auth.forced_sign_out_days',
  '0',
  'number',
  'auth',
  'Number of days after which users are forced to re-authenticate. Set to 0 to disable.',
  false,
  0,
  365
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

