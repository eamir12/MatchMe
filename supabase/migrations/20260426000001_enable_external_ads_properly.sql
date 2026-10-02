-- Properly enable external ads system with correct JSON types
-- This sets ads.external.enabled = true and disables internal ads
-- All values use proper JSON types (booleans, arrays, numbers) not strings

BEGIN;

-- Enable external ads (boolean, not string)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.external.enabled', 'true', 'boolean', 'ads', 'Enable/disable external ad network system', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = 'true',
  config_type = 'boolean',
  updated_at = NOW();

-- Disable internal ads (mutual exclusivity) (boolean, not string)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.internal.enabled', 'false', 'boolean', 'ads', 'Enable/disable internal sponsored ads system', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = 'false',
  config_type = 'boolean',
  updated_at = NOW();

-- External ad placements (JSON array, not JSON string)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]', 'array', 'ads', 'Allowed ad placements for external system', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '["home_inline", "matches_inline", "chats_inline", "events_inline"]',
  config_type = 'array',
  updated_at = NOW();

-- External ad tiers (JSON array - using actual database tier names: free, plus, gold, platinum)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.external.allowed_tiers', '["free"]', 'array', 'ads', 'User tiers eligible for external ads', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '["free"]',
  config_type = 'array',
  updated_at = NOW();

-- External ad platforms (JSON array)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.external.allowed_platforms', '["android", "ios", "web"]', 'array', 'ads', 'Platforms where external ads can appear', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '["android", "ios", "web"]',
  config_type = 'array',
  updated_at = NOW();

-- Rate limit: maximum impressions per user per day (number, not string)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.external.max_impressions_per_user_per_day', '51', 'number', 'ads', 'Maximum impressions per user per day', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '51',
  config_type = 'number',
  updated_at = NOW();

-- Rate limit: maximum impressions per user per hour (number, not string)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.external.max_impressions_per_user_per_hour', '28', 'number', 'ads', 'Maximum impressions per user per hour', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '28',
  config_type = 'number',
  updated_at = NOW();

-- Disable internal sponsored cards (boolean)
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.internal.sponsored_cards_enabled', 'false', 'boolean', 'ads', 'Controls whether Supabase-managed sponsored cards can be shown', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = 'false',
  config_type = 'boolean',
  updated_at = NOW();

COMMIT;

-- Verify the changes
SELECT config_key, config_value, config_type, updated_at
FROM public.app_config
WHERE config_key LIKE 'ads.%'
ORDER BY config_key;
