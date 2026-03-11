-- Add referral.base_url to app_config
INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES
('referral.base_url', '"https://matchme.app/invite"', 'string', 'referral', 'Base URL for referral links (e.g. https://matchme.app/invite or matchme://invite)', false)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    description = EXCLUDED.description;
