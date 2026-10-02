-- Insert development mode configuration into app_config table

INSERT INTO app_config (
  config_key, 
  config_value, 
  config_type, 
  category,
  description,
  is_user_configurable
)
VALUES (
  'auth.passkeys.development_mode',
  '"true"'::jsonb,
  'boolean',
  'auth',
  'Enable development mode for passkey testing. When true, uses development_rp_id instead of production RP ID.',
  false
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"true"'::jsonb;

INSERT INTO app_config (
  config_key, 
  config_value, 
  config_type, 
  category,
  description,
  is_user_configurable
)
VALUES (
  'auth.passkeys.development_rp_id',
  '"localhost"'::jsonb,
  'string',
  'auth',
  'Development RP ID for testing passkeys without domain association. Use "localhost" for testing.',
  false
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"localhost"'::jsonb;

-- Verify the inserts
SELECT config_key, config_value, config_type FROM app_config 
WHERE config_key LIKE 'auth.passkeys%'
ORDER BY config_key;
