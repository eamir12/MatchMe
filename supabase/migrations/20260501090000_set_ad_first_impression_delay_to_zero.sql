-- Set first impression delay to 0 for testing sponsored ads
-- This allows ads to show immediately after app startup

BEGIN;

INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES ('ads.internal.first_impression_delay_seconds', '0', 'number', 'ads', 'Delay in seconds before first ad impression is allowed after app startup', false)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = '0',
  config_type = 'number',
  category = 'ads',
  description = 'Delay in seconds before first ad impression is allowed after app startup',
  is_user_configurable = false;

COMMIT;
