-- Add profile wizard configuration limits from user requirements:
--   1. At least one sub-intent, max 10 per main intent
--   2. At least one main interest, max 10 main interests
--   3. Between 0 and 10 sub-interests per main interest category

INSERT INTO app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value) VALUES
('profile.min_sub_intents', '1', 'number', 'profile', 'Minimum number of sub-intents required per selected main intent', false, 0, 10),
('profile.max_sub_intents', '10', 'number', 'profile', 'Maximum number of sub-intents allowed per selected main intent', false, 1, 20),
('profile.min_main_interests', '1', 'number', 'profile', 'Minimum number of main interest categories required per intent', false, 0, 20),
('profile.max_main_interests', '10', 'number', 'profile', 'Maximum number of main interest categories allowed per intent', false, 1, 50),
('profile.max_sub_interests_per', '10', 'number', 'profile', 'Maximum number of sub-interests per main interest category', false, 1, 50)
ON CONFLICT (config_key) DO UPDATE SET
    config_value = EXCLUDED.config_value,
    config_type = EXCLUDED.config_type,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    is_user_configurable = EXCLUDED.is_user_configurable,
    min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value;
