-- Fix: same FCM token registered for multiple users on one phone.
-- FCM delivery is per-token, so John's phone was receiving Eran's pushes
-- (and vice versa) when test accounts shared a device.
-- upsert_user_session now steals the token: clears it from all OTHER users.
-- Plus one-time cleanup of existing shared tokens (keep most recent).
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
  p_mfa_verified boolean DEFAULT false,
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
  v_user_timezone text;
  v_fcm_token text;
BEGIN
  v_platform := NULLIF(btrim(COALESCE(p_platform, '')), '');
  IF v_platform IS NULL THEN
    RAISE EXCEPTION 'platform is required';
  END IF;

  v_device_id := NULLIF(btrim(COALESCE(p_device_id, '')), '');
  v_user_timezone := NULLIF(btrim(COALESCE(p_metadata ->> 'user_timezone', '')), '');

  IF v_user_timezone IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM pg_timezone_names
    WHERE name = v_user_timezone
  ) THEN
    v_user_timezone := NULL;
  END IF;

  IF auth.jwt() ->> 'role' <> 'service_role' THEN
    IF auth.uid() IS NULL OR auth.uid()::uuid <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to create or modify sessions for other users';
    END IF;
  END IF;

  v_fcm_token := NULLIF(btrim(COALESCE(p_metadata ->> 'fcm_token', '')), '');
  IF v_fcm_token IS NOT NULL AND length(v_fcm_token) <= 10 THEN
    v_fcm_token := NULL;
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
      mfa_verified,
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
      COALESCE(p_mfa_verified, false),
      p_metadata
    )
    ON CONFLICT (user_id, platform, device_id)
      WHERE device_id IS NOT NULL AND btrim(device_id) <> ''
    DO UPDATE SET
      platform = EXCLUDED.platform,
      client_id = EXCLUDED.client_id,
      token_hash = EXCLUDED.token_hash,
      refresh_token_hash = EXCLUDED.refresh_token_hash,
      device_model = EXCLUDED.device_model,
      user_agent = EXCLUDED.user_agent,
      ip = EXCLUDED.ip,
      country = COALESCE(NULLIF(btrim(EXCLUDED.country), ''), user_session.country),
      last_active_at = NOW(),
      expires_at = EXCLUDED.expires_at,
      revoked = false,
      revoked_at = NULL,
      logout_at = NULL,
      terminated_by = NULL,
      is_persistent = EXCLUDED.is_persistent,
      auth_method = EXCLUDED.auth_method,
      mfa_verified = COALESCE(EXCLUDED.mfa_verified, false),
      metadata = COALESCE(EXCLUDED.metadata, '{}'::jsonb)
    RETURNING id INTO v_id;

    -- Steal: same token must belong to exactly one user. Clear it from
    -- all OTHER users so a shared phone stops getting both users' pushes.
    IF v_fcm_token IS NOT NULL THEN
      UPDATE public.user_session
      SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'fcm_token' - 'fcm_token_updated_at'),
          last_active_at = last_active_at
      WHERE user_id <> p_user_id
        AND (metadata ->> 'fcm_token') = v_fcm_token;
    END IF;

    IF v_user_timezone IS NOT NULL THEN
      UPDATE public.users
      SET user_timezone = v_user_timezone
      WHERE id = p_user_id
        AND user_timezone IS DISTINCT FROM v_user_timezone;
    END IF;

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
    mfa_verified,
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
    COALESCE(p_mfa_verified, false),
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
    country = COALESCE(NULLIF(btrim(EXCLUDED.country), ''), user_session.country),
    last_active_at = NOW(),
    expires_at = EXCLUDED.expires_at,
    revoked = EXCLUDED.revoked,
    is_persistent = EXCLUDED.is_persistent,
    auth_method = EXCLUDED.auth_method,
    mfa_verified = COALESCE(EXCLUDED.mfa_verified, false),
    metadata = COALESCE(EXCLUDED.metadata, '{}'::jsonb);

  IF v_fcm_token IS NOT NULL THEN
    UPDATE public.user_session
    SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'fcm_token' - 'fcm_token_updated_at')
    WHERE user_id <> p_user_id
      AND (metadata ->> 'fcm_token') = v_fcm_token;
  END IF;

  IF v_user_timezone IS NOT NULL THEN
    UPDATE public.users
    SET user_timezone = v_user_timezone
    WHERE id = p_user_id
      AND user_timezone IS DISTINCT FROM v_user_timezone;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_user_session(
  uuid,
  text,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  inet,
  text,
  timestamptz,
  boolean,
  text,
  boolean,
  jsonb
) TO authenticated;

-- One-time cleanup: token cpRuttOpQAab... is currently shared by 3 users on
-- device V1TDS35H.83-20-5-8-4. Keep the most-recent row per token, strip the
-- token from older rows (they stay logged in, just stop getting pushes).
WITH ranked AS (
  SELECT
    id,
    metadata ->> 'fcm_token' AS tok,
    ROW_NUMBER() OVER (
      PARTITION BY metadata ->> 'fcm_token'
      ORDER BY last_active_at DESC NULLS LAST, created_at DESC NULLS LAST
    ) AS rn
  FROM public.user_session
  WHERE revoked = false
    AND metadata ->> 'fcm_token' IS NOT NULL
    AND length(btrim(metadata ->> 'fcm_token')) > 10
)
UPDATE public.user_session us
SET metadata = (COALESCE(us.metadata, '{}'::jsonb) - 'fcm_token' - 'fcm_token_updated_at')
FROM ranked r
WHERE us.id = r.id
  AND r.rn > 1;

COMMIT;
