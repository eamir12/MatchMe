-- Standardize ad system configuration to use app_config table for both internal and external systems
-- This migration consolidates configuration from ad_system_config into app_config

BEGIN;

-- Create a view for easier querying of ad system config
-- Note: All values in app_config are stored as TEXT, so we cast them as needed
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
