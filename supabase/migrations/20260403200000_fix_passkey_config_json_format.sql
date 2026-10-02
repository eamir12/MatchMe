-- Fix malformed JSON values in passkey configuration
-- The development_rp_id was inserted as plain text instead of JSON string

-- Fix development_rp_id to be proper JSON string
UPDATE app_config 
SET config_value = '"localhost"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id' 
  AND config_value::text = 'localhost';

-- Fix development_mode to be proper JSON boolean
UPDATE app_config 
SET config_value = 'true'::jsonb
WHERE config_key = 'auth.passkeys.development_mode' 
  AND config_value::text = 'true';

-- Verify the fixes
SELECT config_key, config_value, config_type FROM app_config 
WHERE config_key IN ('auth.passkeys.development_mode', 'auth.passkeys.development_rp_id')
ORDER BY config_key;
