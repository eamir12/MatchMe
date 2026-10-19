BEGIN;

-- ---------------------------------------------------------------------------
-- WNS (Windows Push Notification Service) support.
-- The MSIX-packaged Windows client registers a WNS channel URI into its
-- platform='windows' user_session row (metadata wns_channel_uri). Server
-- senders (push-message, cron-jobs) dispatch toasts through
-- supabase/functions/_shared/wns.ts with these credentials.
-- ---------------------------------------------------------------------------

-- 1. Single-row cache of the MSA app-only OAuth token used to authenticate
-- WNS POSTs. Keyed id=1 so concurrent invocations upsert over each other.
CREATE TABLE IF NOT EXISTS public.wns_token_cache (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  access_token text NOT NULL,
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- RLS on with no policies: anon/authenticated cannot touch the cached
-- OAuth secret through the API at all. Edge functions read/write it with the
-- service_role key, which bypasses RLS, so this is zero-cost safety.
ALTER TABLE public.wns_token_cache ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.wns_token_cache FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wns_token_cache TO service_role;

-- 2. Prune a WNS channel registration that WNS reported as expired (410).
-- Mirrors clear_user_session_fcm_token, including the metadata key-pair
-- convention (<key> + <key>_updated_at).
CREATE OR REPLACE FUNCTION public.clear_user_session_wns_channel(p_wns_channel_uri text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uri text;
  v_count integer := 0;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_uri := NULLIF(btrim(COALESCE(p_wns_channel_uri, '')), '');
  IF v_uri IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.user_session
  SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'wns_channel_uri' - 'wns_channel_uri_updated_at')
  WHERE NULLIF(btrim(COALESCE(metadata->>'wns_channel_uri', '')), '') = v_uri;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- 3. upsert_user_session: same functional behavior as
--    20262110000000_server_side_country_from_coordinates.sql, extended with
--    wns_channel_uri sanitization + cross-user steal (a WNS channel is
--    registered to exactly one user, like an FCM token).
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
  v_wns_channel text;
  v_country text;
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

  -- Country: trust the client when provided; otherwise derive it server-side
  -- from the user's latest stored coordinates.
  v_country := NULLIF(btrim(COALESCE(p_country, '')), '');
  IF v_country IS NULL THEN
    SELECT NULLIF(btrim(ul.country_code), '')
    INTO v_country
    FROM public.user_locations ul
    WHERE ul.user_id = p_user_id
      AND ul.country_code IS NOT NULL
    ORDER BY ul.updated_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  v_fcm_token := NULLIF(btrim(COALESCE(p_metadata ->> 'fcm_token', '')), '');
  IF v_fcm_token IS NOT NULL AND length(v_fcm_token) <= 10 THEN
    v_fcm_token := NULL;
  END IF;

  -- WNS channel URI (Windows push): accept only well-formed *.notify.windows.com
  -- https endpoints, dropping anything else so junk metadata never reaches the
  -- server senders.
  v_wns_channel := NULLIF(btrim(COALESCE(p_metadata ->> 'wns_channel_uri', '')), '');
  IF v_wns_channel IS NOT NULL AND (
    length(v_wns_channel) < 20
    OR v_wns_channel NOT ILIKE 'https://%'
    OR v_wns_channel NOT ILIKE '%.notify.windows.com%'
  ) THEN
    v_wns_channel := NULL;
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
      v_country,
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

    -- Steal: same FCM token must belong to exactly one user.
    IF v_fcm_token IS NOT NULL THEN
      UPDATE public.user_session
      SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'fcm_token' - 'fcm_token_updated_at'),
          last_active_at = last_active_at
      WHERE user_id <> p_user_id
        AND (metadata ->> 'fcm_token') = v_fcm_token;
    END IF;

    -- Steal: same WNS channel must belong to exactly one user.
    IF v_wns_channel IS NOT NULL THEN
      UPDATE public.user_session
      SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'wns_channel_uri' - 'wns_channel_uri_updated_at'),
          last_active_at = last_active_at
      WHERE user_id <> p_user_id
        AND (metadata ->> 'wns_channel_uri') = v_wns_channel;
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
    v_country,
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

  IF v_wns_channel IS NOT NULL THEN
    UPDATE public.user_session
    SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'wns_channel_uri' - 'wns_channel_uri_updated_at')
    WHERE user_id <> p_user_id
      AND (metadata ->> 'wns_channel_uri') = v_wns_channel;
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
  uuid, text, uuid, text, text, text, text, text, text, inet, text,
  timestamptz, boolean, text, boolean, jsonb
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.clear_user_session_wns_channel(text) TO service_role;

COMMIT;
