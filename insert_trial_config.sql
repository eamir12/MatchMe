-- Add Trial Configuration to app_config
-- config_value is a JSONB column, so strings must be double-quoted (e.g. '"platinum"')
-- Numbers can be plain (e.g. '72')

INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
VALUES
('subscription.trial_duration_hours', '72', 'number', 'profile', 'Duration of the initial free trial in hours', false, 0, 720),
('subscription.trial_tier_id', '"platinum"', 'string', 'profile', 'The subscription tier ID to grant during the trial period', false, null, null)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description;
