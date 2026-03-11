BEGIN;

CREATE OR REPLACE FUNCTION public.upsert_user_session(
  p_user_id uuid,
  p_platform text,
  p_id uuid DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_token_hash text DEFAULT NULL,
  p_refresh_token_hash text DEFAULT NULL,
  p_device_id text DEFAULT NULL,
  p_device_model text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_ip inet DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_is_persistent boolean DEFAULT false,
  p_auth_method text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_platform text;
  v_device_id text;
BEGIN
  v_platform := NULLIF(btrim(COALESCE(p_platform, '')), '');
  IF v_platform IS NULL THEN
    RAISE EXCEPTION 'platform is required';
  END IF;

  v_device_id := NULLIF(btrim(COALESCE(p_device_id, '')), '');

  IF auth.jwt() ->> 'role' <> 'service_role' THEN
    IF auth.uid() IS NULL OR auth.uid()::uuid <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to create or modify sessions for other users';
    END IF;
  END IF;

  IF v_device_id IS NOT NULL THEN
    INSERT INTO public.user_session (
      id,
      user_id,
      client_id,
      token_hash,
      refresh_token_hash,
      platform,
      device_id,
      device_model,
      user_agent,
      ip,
      country,
      created_at,
      last_active_at,
      expires_at,
      is_persistent,
      auth_method,
      metadata
    )
    VALUES (
      COALESCE(p_id, gen_random_uuid()),
      p_user_id,
      p_client_id,
      p_token_hash,
      p_refresh_token_hash,
      v_platform,
      v_device_id,
      p_device_model,
      p_user_agent,
      p_ip,
      p_country,
      NOW(),
      NOW(),
      p_expires_at,
      p_is_persistent,
      p_auth_method,
      p_metadata
    )
    ON CONFLICT (user_id, platform, device_id)
      WHERE device_id IS NOT NULL AND btrim(device_id) <> ''
    DO UPDATE SET
      client_id = EXCLUDED.client_id,
      token_hash = EXCLUDED.token_hash,
      refresh_token_hash = EXCLUDED.refresh_token_hash,
      device_model = EXCLUDED.device_model,
      user_agent = EXCLUDED.user_agent,
      ip = EXCLUDED.ip,
      country = EXCLUDED.country,
      last_active_at = NOW(),
      expires_at = EXCLUDED.expires_at,
      revoked = false,
      revoked_at = NULL,
      logout_at = NULL,
      terminated_by = NULL,
      is_persistent = EXCLUDED.is_persistent,
      auth_method = EXCLUDED.auth_method,
      metadata = COALESCE(EXCLUDED.metadata, '{}'::jsonb)
    RETURNING id INTO v_id;

    RETURN v_id;
  END IF;

  v_id := COALESCE(p_id, gen_random_uuid());

  INSERT INTO public.user_session (
    id,
    user_id,
    client_id,
    token_hash,
    refresh_token_hash,
    platform,
    device_id,
    device_model,
    user_agent,
    ip,
    country,
    created_at,
    last_active_at,
    expires_at,
    is_persistent,
    auth_method,
    metadata
  )
  VALUES (
    v_id,
    p_user_id,
    p_client_id,
    p_token_hash,
    p_refresh_token_hash,
    v_platform,
    NULL,
    p_device_model,
    p_user_agent,
    p_ip,
    p_country,
    NOW(),
    NOW(),
    p_expires_at,
    p_is_persistent,
    p_auth_method,
    p_metadata
  )
  ON CONFLICT (id)
  DO UPDATE SET
    client_id = EXCLUDED.client_id,
    token_hash = EXCLUDED.token_hash,
    refresh_token_hash = EXCLUDED.refresh_token_hash,
    platform = EXCLUDED.platform,
    device_id = EXCLUDED.device_id,
    device_model = EXCLUDED.device_model,
    user_agent = EXCLUDED.user_agent,
    ip = EXCLUDED.ip,
    country = EXCLUDED.country,
    last_active_at = NOW(),
    expires_at = EXCLUDED.expires_at,
    revoked = EXCLUDED.revoked,
    is_persistent = EXCLUDED.is_persistent,
    auth_method = EXCLUDED.auth_method,
    metadata = COALESCE(EXCLUDED.metadata, '{}'::jsonb);

  RETURN v_id;
END;
$$;

COMMIT;

