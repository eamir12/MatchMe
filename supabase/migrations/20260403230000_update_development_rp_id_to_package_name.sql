-- Update development RP ID to use the app's package name for Android testing
-- This allows Android credential manager to validate against the app's signing certificate

UPDATE app_config 
SET config_value = '"com.example.matchme"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id';

-- Verify the change
SELECT config_key, config_value FROM app_config 
WHERE config_key = 'auth.passkeys.development_rp_id';
