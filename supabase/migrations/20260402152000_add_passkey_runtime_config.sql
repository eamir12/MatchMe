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
    'auth.passkeys.relying_party_id',
    to_jsonb(''::text),
    'string',
    'auth',
    'WebAuthn relying party ID used to create and validate passkey authentication challenges',
    false,
    null,
    null
  ),
  (
    'auth.passkeys.server_base_url',
    to_jsonb(''::text),
    'string',
    'auth',
    'HTTPS base URL of the relying party server that starts and finishes passkey sign-in requests',
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
