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
    'auth.passkeys.start_registration_path',
    to_jsonb('/functions/v1/passkeys-registration-start'::text),
    'string',
    'auth',
    'Relative path on the passkey relying party server that starts an enrollment challenge',
    false,
    null,
    null
  ),
  (
    'auth.passkeys.finish_registration_path',
    to_jsonb('/functions/v1/passkeys-registration-finish'::text),
    'string',
    'auth',
    'Relative path on the passkey relying party server that verifies a completed enrollment attestation',
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
