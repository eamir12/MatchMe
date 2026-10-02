-- Update development RP ID to use 'android' for Android credential manager testing
-- 'android' is a special test value recognized by Android's credential manager

UPDATE app_config 
SET config_value = '"android"'::jsonb
WHERE config_key = 'auth.passkeys.development_rp_id';

-- Verify the change
SELECT config_key, config_value FROM app_config 
WHERE config_key = 'auth.passkeys.development_rp_id';
