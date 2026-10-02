INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  (
    'subscription.enabled',
    'true',
    'boolean',
    'subscription',
    'Controls whether the subscription feature is shown in the app',
    false,
    null,
    null
  ),
  (
    'referral.enabled',
    'true',
    'boolean',
    'referral',
    'Controls whether the invite friends feature is shown in the app',
    false,
    null,
    null
  )
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;
