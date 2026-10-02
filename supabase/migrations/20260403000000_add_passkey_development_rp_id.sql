-- Add development RP ID configuration for testing
-- This allows testing passkeys without domain association setup

INSERT INTO app_config (config_key, config_value, config_type, description)
VALUES (
  'auth.passkeys.development_rp_id',
  '"localhost"'::jsonb,
  'string',
  'Development RP ID for testing passkeys without domain association. Use "localhost" or "android" for testing.'
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"localhost"'::jsonb,
  config_type = EXCLUDED.config_type,
  description = EXCLUDED.description;

-- Add flag to enable development mode
INSERT INTO app_config (config_key, config_value, config_type, description)
VALUES (
  'auth.passkeys.development_mode',
  '"false"'::jsonb,
  'boolean',
  'Enable development mode for passkey testing. When true, uses development_rp_id instead of production RP ID.'
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '"false"'::jsonb,
  config_type = EXCLUDED.config_type,
  description = EXCLUDED.description;
