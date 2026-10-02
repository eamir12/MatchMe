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
    'auth.passkeys.start_authentication_path',
    to_jsonb('/functions/v1/passkeys-authentication-start'::text),
    'string',
    'auth',
    'Relative path on the passkey relying party server that starts a sign-in challenge',
    false,
    null,
    null
  ),
  (
    'auth.passkeys.finish_authentication_path',
    to_jsonb('/functions/v1/passkeys-authentication-finish'::text),
    'string',
    'auth',
    'Relative path on the passkey relying party server that verifies a completed sign-in assertion',
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
