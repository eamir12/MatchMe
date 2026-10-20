-- Master switch for the admin app's Supabase monitoring (System Health).
-- false = no live probes, no status page polling, no health history sampling,
-- and the System Health nav item / dashboard pill are hidden.
INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES (
  'admin.supabase_monitoring.enabled',
  'true',
  'boolean',
  'admin',
  'Controls whether the admin app monitors Supabase health and shows the System Health screens and indicators',
  false,
  null,
  null
)
ON CONFLICT (config_key) DO UPDATE SET
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

SELECT config_key, config_value, config_type
FROM public.app_config
WHERE config_key = 'admin.supabase_monitoring.enabled';
