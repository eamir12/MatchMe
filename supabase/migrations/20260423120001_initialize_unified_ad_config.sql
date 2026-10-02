-- Initialize unified ad system configuration in app_config table
-- This ensures both internal and external systems use the same configuration table

BEGIN;

-- INTERNAL ADS SYSTEM CONFIGURATION
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES
  ('ads.internal.enabled', 'false', 'boolean', 'ads', 'Enable/disable internal sponsored ads system', false),
  ('ads.internal.free_tier_only', 'true', 'boolean', 'ads', 'When enabled, only free tier users see ads', false),
  ('ads.internal.sponsored_cards_enabled', 'true', 'boolean', 'ads', 'Controls whether Supabase-managed sponsored cards can be shown', false),
  ('ads.internal.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]', 'array', 'ads', 'Allowed ad placements for internal system', false),
  ('ads.internal.allowed_tiers', '["free"]', 'array', 'ads', 'User tiers eligible for internal ads', false),
  ('ads.internal.allowed_platforms', '["android", "ios", "web"]', 'array', 'ads', 'Platforms where internal ads can appear', false),
  ('ads.internal.max_impressions_per_session', '3', 'number', 'ads', 'Maximum sponsored impressions per session', false),
  ('ads.internal.min_minutes_between_impressions', '8', 'number', 'ads', 'Minimum pacing time between impressions', false),
  ('ads.internal.first_impression_delay_seconds', '90', 'number', 'ads', 'Delay before first ad can appear', false),
  ('ads.internal.report_enabled', 'true', 'boolean', 'ads', 'Allow users to report sponsored cards', false),
  ('ads.internal.mobile.native_enabled', 'false', 'boolean', 'ads', 'Enable mobile native network ads', false),
  ('ads.internal.mobile.provider', '"none"', 'string', 'ads', 'Mobile ad provider (none, admob)', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  updated_at = NOW();

-- EXTERNAL ADS SYSTEM CONFIGURATION
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES
  ('ads.external.enabled', 'false', 'boolean', 'ads', 'Enable/disable external ad network system', false),
  ('ads.external.allowed_placements', '["home_inline", "matches_inline", "chats_inline", "events_inline"]', 'array', 'ads', 'Allowed ad placements for external system', false),
  ('ads.external.allowed_tiers', '["free", "premium", "vip"]', 'array', 'ads', 'User tiers eligible for external ads', false),
  ('ads.external.allowed_platforms', '["android", "ios", "web"]', 'array', 'ads', 'Platforms where external ads can appear', false),
  ('ads.external.max_impressions_per_user_per_day', '5', 'number', 'ads', 'Maximum impressions per user per day', false),
  ('ads.external.max_impressions_per_user_per_hour', '2', 'number', 'ads', 'Maximum impressions per user per hour', false),
  ('ads.external.personalized_ads_default', 'false', 'boolean', 'ads', 'Default personalization setting', false),
  ('ads.external.show_consent_form', 'true', 'boolean', 'ads', 'Show consent form to users', false),
  ('ads.external.min_user_age_for_personalization', '13', 'number', 'ads', 'Minimum age for personalized ads', false),
  ('ads.external.mediation_enabled', 'false', 'boolean', 'ads', 'Enable ad mediation', false),
  ('ads.external.admob_enabled', 'false', 'boolean', 'ads', 'Enable Google AdMob', false),
  ('ads.external.facebook_enabled', 'false', 'boolean', 'ads', 'Enable Facebook Audience Network', false),
  ('ads.external.applovin_enabled', 'false', 'boolean', 'ads', 'Enable AppLovin', false),
  ('ads.external.unity_enabled', 'false', 'boolean', 'ads', 'Enable Unity Ads', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  updated_at = NOW();

COMMIT;
