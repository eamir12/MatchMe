-- Add master controls for internal ad system (placements and platforms)
-- These settings will be enforced at the system level and restrict individual ad settings

BEGIN;

-- Add default configuration values for internal ad master controls
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES
  ('ads.internal.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]', 'array', 'ads', 'Master list of allowed placements for internal ads. Individual ads cannot use placements not in this list.', false),
  ('ads.internal.allowed_platforms', '["android", "ios", "web", "windows", "macos", "linux"]', 'array', 'ads', 'Master list of allowed platforms for internal ads. Individual ads cannot use platforms not in this list.', false),
  ('ads.internal.allowed_tiers', '["free"]', 'array', 'ads', 'Master list of allowed subscription tiers for internal ads.', false)
ON CONFLICT (config_key) DO NOTHING;

-- Update the ad_system_config_view to include the master controls
CREATE OR REPLACE VIEW public.ad_system_config_view AS
SELECT 
  'internal' as system_type,
  (SELECT (config_value = 'true') FROM app_config WHERE config_key = 'ads.internal.enabled' LIMIT 1) as is_enabled,
  (SELECT config_value::jsonb FROM app_config WHERE config_key = 'ads.internal.allowed_placements' LIMIT 1) as allowed_placements,
  (SELECT config_value::jsonb FROM app_config WHERE config_key = 'ads.internal.allowed_tiers' LIMIT 1) as allowed_tiers,
  (SELECT config_value::jsonb FROM app_config WHERE config_key = 'ads.internal.allowed_platforms' LIMIT 1) as allowed_platforms,
  (SELECT config_value::integer FROM app_config WHERE config_key = 'ads.internal.max_impressions_per_session' LIMIT 1) as max_impressions_per_session,
  (SELECT config_value::integer FROM app_config WHERE config_key = 'ads.internal.min_minutes_between_impressions' LIMIT 1) as min_minutes_between_impressions,
  (SELECT config_value::integer FROM app_config WHERE config_key = 'ads.internal.first_impression_delay_seconds' LIMIT 1) as first_impression_delay_seconds
UNION ALL
SELECT 
  'external' as system_type,
  (SELECT (config_value = 'true') FROM app_config WHERE config_key = 'ads.external.enabled' LIMIT 1) as is_enabled,
  (SELECT config_value::jsonb FROM app_config WHERE config_key = 'ads.external.allowed_placements' LIMIT 1) as allowed_placements,
  (SELECT config_value::jsonb FROM app_config WHERE config_key = 'ads.external.allowed_tiers' LIMIT 1) as allowed_tiers,
  (SELECT config_value::jsonb FROM app_config WHERE config_key = 'ads.external.allowed_platforms' LIMIT 1) as allowed_platforms,
  (SELECT config_value::integer FROM app_config WHERE config_key = 'ads.external.max_impressions_per_user_per_day' LIMIT 1) as max_impressions_per_session,
  (SELECT config_value::integer FROM app_config WHERE config_key = 'ads.external.max_impressions_per_user_per_hour' LIMIT 1) as min_minutes_between_impressions,
  NULL as first_impression_delay_seconds;

COMMIT;
