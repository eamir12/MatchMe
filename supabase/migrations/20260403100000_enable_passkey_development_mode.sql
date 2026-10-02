-- Enable development mode for passkey testing
-- This allows testing without domain association setup

UPDATE app_config 
SET config_value = '"true"'::jsonb
WHERE config_key = 'auth.passkeys.development_mode';

UPDATE app_config 
SET config_value = '"localhost"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id';

-- Verify the changes
SELECT 'Development mode enabled for passkey testing' as status;
SELECT config_key, config_value FROM app_config 
WHERE config_key IN ('auth.passkeys.development_mode', 'auth.passkeys.development_rp_id');
