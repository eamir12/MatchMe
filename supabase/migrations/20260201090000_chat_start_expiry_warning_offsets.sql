INSERT INTO app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES (
  'matches.chat_start_expiry_warning_seconds',
  '[3000, 300, 60]',
  'array',
  'notification',
  'When to warn about match chat-start expiry (seconds before expiry)',
  false,
  null,
  null
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;
