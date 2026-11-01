-- Migration: stop upsert_user_session() from enumerating pg_timezone_names.
-- Date: 2026-10-29
--
-- Problem (measured 2026-10-29): the timezone guard inside this function ran
--
--   SELECT 1 FROM pg_timezone_names WHERE name = v_user_timezone
--
--   pg_timezone_names is a view over the pg_timezone_names() set-returning
--   function, which materialises every zone (598 rows here) and filters after
--   the fact. EXPLAIN ANALYZE on production: 262 ms for one lookup; the
--   statement aggregate shows 438 ms mean / 5,876 ms max. The client sends
--   metadata.user_timezone on every call (session_service.dart), so every
--   session upsert paid it while holding its session/users row lock.
--
--   RPC aggregate before this change: 194 calls, 1,208 ms mean, 7,494 ms max.
--
-- Fix: validate with a direct lookup -- `now() AT TIME ZONE <name>` resolves a
-- single name and raises SQLSTATE 22023 (invalid_parameter_value) when the zone
-- is unknown, which is converted back to NULL. Measured on the local scratch
-- cluster: 591 ms per pg_timezone_names lookup vs 0.002 ms for AT TIME ZONE.
--
-- One documented widening: AT TIME ZONE also accepts POSIX specs that are not
-- IANA names (e.g. 'GMT+3', 'UTC+3' -- 'Etc/GMT+3' is IANA, 'GMT+3' is not).
-- Those are now stored instead of dropped. Nothing is created that PostgreSQL
-- cannot resolve, and the device only ever sends IANA names; the birthday job
-- joins user_timezone against pg_timezone_names, so such a value would fall
-- back to UTC there. Everything actually invalid is still dropped.
--
-- Blast radius: one function body, one branch. CREATE OR REPLACE preserves the
-- owner and ACL (postgres/service_role/authenticated stays intact); the GRANT
-- at the bottom is repeated for explicitness. No table, index or trigger
-- changes.

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

  -- Validate with a single time zone lookup instead of enumerating
  -- pg_timezone_names, which is a set-returning function over the whole tz
  -- database (262 ms per call measured on this instance, 438 ms mean and
  -- 5.9 s worst case under load). AT TIME ZONE resolves one name and raises
  -- 22023 for unknown ones.
  IF v_user_timezone IS NOT NULL THEN
    BEGIN
      PERFORM now() AT TIME ZONE v_user_timezone;
    EXCEPTION WHEN invalid_parameter_value THEN
      v_user_timezone := NULL;
    END;
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

-- Verification (run after applying):
--
--   -- No pg_timezone_names scans remain in the function:
--   select proname from pg_proc
--   where proname = 'upsert_user_session' and prosrc ilike '%pg_timezone_names%';
--   -- expect 0 rows
--
--   -- Live latency (take two samples a few minutes apart):
--   select calls, mean_exec_time, max_exec_time
--   from extensions.pg_stat_statements
--   where query ~ '"public"."upsert_user_session"';
--   -- live mean = delta(total_exec_time) / delta(calls) over the window
