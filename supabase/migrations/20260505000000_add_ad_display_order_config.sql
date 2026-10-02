--- Add ads.display_order config key to allow admin control over which ad system appears first
--- when both internal and external ads are enabled simultaneously.
--- Values: 'external_first' (default) or 'internal_first'

BEGIN;

INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable
)
VALUES (
  'ads.display_order',
  '"external_first"',
  'string',
  'ads',
  'Display order when both internal and external ads are enabled. Values: external_first, internal_first',
  false
)
ON CONFLICT (config_key) DO NOTHING;

COMMIT;
