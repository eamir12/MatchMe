CREATE TABLE IF NOT EXISTS public.passkey_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  email text,
  challenge text NOT NULL UNIQUE,
  challenge_type text NOT NULL CHECK (challenge_type IN ('registration', 'authentication')),
  rp_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
  expires_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()) + interval '10 minutes'
);

CREATE INDEX IF NOT EXISTS idx_passkey_challenges_lookup
  ON public.passkey_challenges (request_id, challenge_type);

CREATE INDEX IF NOT EXISTS idx_passkey_challenges_expiry
  ON public.passkey_challenges (expires_at);

CREATE TABLE IF NOT EXISTS public.passkey_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  credential_id text NOT NULL UNIQUE,
  public_key text NOT NULL,
  counter bigint NOT NULL DEFAULT 0,
  rp_id text NOT NULL,
  transports text[] NOT NULL DEFAULT ARRAY[]::text[],
  credential_device_type text,
  credential_backed_up boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
  last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_passkey_credentials_user_id
  ON public.passkey_credentials (user_id);

CREATE INDEX IF NOT EXISTS idx_passkey_credentials_rp_id
  ON public.passkey_credentials (rp_id);

ALTER TABLE public.passkey_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.passkey_credentials ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own passkey credentials" ON public.passkey_credentials;
CREATE POLICY "Users can view their own passkey credentials"
  ON public.passkey_credentials
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete their own passkey credentials" ON public.passkey_credentials;
CREATE POLICY "Users can delete their own passkey credentials"
  ON public.passkey_credentials
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

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
    'auth.passkeys.android_apk_key_hash',
    to_jsonb('nSPXJ93P8O5mS7iICbkWxo1Et5xSeOB7kHw0N_ZC81c'::text),
    'string',
    'auth',
    'Base64URL-encoded SHA256 hash of the Android signing certificate used for native passkey origin verification.',
    false,
    null,
    null
  ),
  (
    'auth.passkeys.allowed_origins',
    '[]'::jsonb,
    'json',
    'auth',
    'Optional additional WebAuthn origins to trust when verifying passkeys. Leave empty to use the derived RP origin and Android native origin only.',
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
