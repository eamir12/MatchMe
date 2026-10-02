-- Create a user_session table to track user sessions and platform

CREATE TABLE IF NOT EXISTS user_session (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id TEXT,
    token_hash TEXT,
    refresh_token_hash TEXT,
    platform TEXT NOT NULL,
    device_id TEXT,
    device_model TEXT,
    user_agent TEXT,
    ip INET,
    country TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    revoked BOOLEAN NOT NULL DEFAULT FALSE,
    revoked_at TIMESTAMPTZ,
    logout_at TIMESTAMPTZ,
    is_persistent BOOLEAN NOT NULL DEFAULT FALSE,
    auth_method TEXT,
    mfa_verified BOOLEAN,
    last_rotated_at TIMESTAMPTZ,
    terminated_by TEXT,
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_user_session_user_id ON user_session(user_id);
CREATE INDEX IF NOT EXISTS idx_user_session_expires_at ON user_session(expires_at);
CREATE INDEX IF NOT EXISTS idx_user_session_last_active ON user_session(last_active_at);
CREATE INDEX IF NOT EXISTS idx_user_session_active_per_user ON user_session(user_id) WHERE revoked = false;

-- Enable RLS
ALTER TABLE user_session ENABLE ROW LEVEL SECURITY;

-- Policies: allow users to manage their own sessions
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users can manage own sessions' AND tablename = 'user_session'
  ) THEN
    CREATE POLICY "Users can manage own sessions" ON user_session
      FOR ALL USING (auth.uid() = user_id);
  END IF;
END;
$$;

-- Policy: service role full access
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Service role full access' AND tablename = 'user_session'
  ) THEN
    CREATE POLICY "Service role full access" ON user_session
      FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
  END IF;
END;
$$;

-- Function to upsert a session (callable by authenticated users)
CREATE OR REPLACE FUNCTION upsert_user_session(
  p_user_id UUID,
  p_platform TEXT,
  p_id UUID DEFAULT NULL,
  p_client_id TEXT DEFAULT NULL,
  p_token_hash TEXT DEFAULT NULL,
  p_refresh_token_hash TEXT DEFAULT NULL,
  p_device_id TEXT DEFAULT NULL,
  p_device_model TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_ip INET DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
  p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_is_persistent BOOLEAN DEFAULT FALSE,
  p_auth_method TEXT DEFAULT NULL,
  p_mfa_verified BOOLEAN DEFAULT FALSE,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id UUID := COALESCE(p_id, gen_random_uuid());
BEGIN
  SET search_path = 'public';

  -- Security: ensure caller is either service_role or the same user
  IF auth.jwt() ->> 'role' <> 'service_role' THEN
    IF auth.uid() IS NULL OR auth.uid()::uuid <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to create or modify sessions for other users';
    END IF;
  END IF;

  INSERT INTO user_session (
    id, user_id, client_id, token_hash, refresh_token_hash,
    platform, device_id, device_model, user_agent, ip, country,
    created_at, last_active_at, expires_at, is_persistent, auth_method, mfa_verified, metadata
  )
  VALUES (
    v_id, p_user_id, p_client_id, p_token_hash, p_refresh_token_hash,
    p_platform, p_device_id, p_device_model, p_user_agent, p_ip, p_country,
    NOW(), NOW(), p_expires_at, p_is_persistent, p_auth_method, COALESCE(p_mfa_verified, FALSE), p_metadata
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
    mfa_verified = COALESCE(EXCLUDED.mfa_verified, FALSE),
    metadata = COALESCE(EXCLUDED.metadata, '{}'::jsonb)
  ;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_user_session(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INET, TEXT, TIMESTAMPTZ, BOOLEAN, TEXT, BOOLEAN, JSONB) TO authenticated;


-- Function to revoke a session
CREATE OR REPLACE FUNCTION revoke_user_session(p_session_id UUID, p_terminated_by TEXT DEFAULT 'user')
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  SET search_path = 'public';

  -- Only allow revoking if caller is service_role or owns the session
  UPDATE user_session
  SET revoked = true, revoked_at = NOW(), terminated_by = p_terminated_by
  WHERE id = p_session_id
    AND (
      auth.jwt() ->> 'role' = 'service_role'
      OR user_id = auth.uid()::uuid
    );
END;
$$;

GRANT EXECUTE ON FUNCTION revoke_user_session(UUID, TEXT) TO authenticated;


-- Revoke all sessions for a user
CREATE OR REPLACE FUNCTION revoke_all_user_sessions(p_user_id UUID, p_terminated_by TEXT DEFAULT 'user')
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  updated_count INTEGER := 0;
BEGIN
  SET search_path = 'public';

  -- Ensure caller is either service_role or the same user
  IF auth.jwt() ->> 'role' <> 'service_role' THEN
    IF auth.uid() IS NULL OR auth.uid()::uuid <> p_user_id THEN
      RAISE EXCEPTION 'Not authorized to revoke sessions for other users';
    END IF;
  END IF;

  UPDATE user_session
  SET revoked = true, revoked_at = NOW(), terminated_by = p_terminated_by
  WHERE user_id = p_user_id AND revoked = false;

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN COALESCE(updated_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION revoke_all_user_sessions(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_all_user_sessions(UUID, TEXT) TO service_role;

-- Prune expired sessions function (should be called by a scheduler)
CREATE OR REPLACE FUNCTION prune_expired_sessions(p_older_than INTERVAL DEFAULT '30 days')
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_count INTEGER := 0;
BEGIN
  SET search_path = 'public';

  DELETE FROM user_session
  WHERE (expires_at IS NOT NULL AND expires_at < NOW() - p_older_than)
  OR (last_active_at < NOW() - p_older_than)
  RETURNING 1 INTO deleted_count;

  RETURN COALESCE(deleted_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION prune_expired_sessions(INTERVAL) TO service_role;

-- Optional: invalidation trigger to update last_active_at on access
CREATE OR REPLACE FUNCTION touch_user_session()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.last_active_at = NOW();
  RETURN NEW;
END;
$$;

-- Note: application should call upsert_user_session when a session is created or refreshed
-- and call revoke_user_session for logouts or security actions
