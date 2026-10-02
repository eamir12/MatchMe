-- Chat Encryption Schema Migration
-- Adds user_chat_keys, user_chat_key_wrappers, encryption columns to chat_messages,
-- indexes, RLS policies, and RPC functions.

-- ============================================================
-- 1. user_chat_keys
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_chat_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  key_version integer NOT NULL,
  public_key text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'retired', 'lost')),
  created_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  UNIQUE (user_id, key_version)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_chat_keys_one_active
  ON public.user_chat_keys(user_id)
  WHERE status = 'active';

-- RLS: users can read their own keys
ALTER TABLE public.user_chat_keys ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_chat_keys_select_own ON public.user_chat_keys;
CREATE POLICY user_chat_keys_select_own
  ON public.user_chat_keys
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS user_chat_keys_insert_own ON public.user_chat_keys;
CREATE POLICY user_chat_keys_insert_own
  ON public.user_chat_keys
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Matched peers can read public key metadata
DROP POLICY IF EXISTS user_chat_keys_select_matched ON public.user_chat_keys;
CREATE POLICY user_chat_keys_select_matched
  ON public.user_chat_keys
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
        AND (m.user1_id = user_chat_keys.user_id OR m.user2_id = user_chat_keys.user_id)
    )
  );

-- ============================================================
-- 2. user_chat_key_wrappers
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_chat_key_wrappers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_chat_key_id uuid NOT NULL REFERENCES public.user_chat_keys(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  wrapper_type text NOT NULL
    CHECK (wrapper_type IN ('recovery_key', 'password')),
  kdf text NOT NULL,
  kdf_iterations integer,
  kdf_salt text NOT NULL,
  wrap_alg text NOT NULL DEFAULT 'AES-256-GCM',
  wrap_nonce text NOT NULL,
  encrypted_private_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_chat_key_id, wrapper_type)
);

CREATE INDEX IF NOT EXISTS idx_user_chat_key_wrappers_user_id
  ON public.user_chat_key_wrappers(user_id);

ALTER TABLE public.user_chat_key_wrappers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_chat_key_wrappers_select_own ON public.user_chat_key_wrappers;
CREATE POLICY user_chat_key_wrappers_select_own
  ON public.user_chat_key_wrappers
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS user_chat_key_wrappers_insert_own ON public.user_chat_key_wrappers;
CREATE POLICY user_chat_key_wrappers_insert_own
  ON public.user_chat_key_wrappers
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS user_chat_key_wrappers_update_own ON public.user_chat_key_wrappers;
CREATE POLICY user_chat_key_wrappers_update_own
  ON public.user_chat_key_wrappers
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- 3. chat_messages encryption columns
-- ============================================================
ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS encryption_scheme text NOT NULL DEFAULT 'v1'
    CHECK (encryption_scheme IN ('v1')),
  ADD COLUMN IF NOT EXISTS sender_key_id uuid REFERENCES public.user_chat_keys(id),
  ADD COLUMN IF NOT EXISTS recipient_key_id uuid REFERENCES public.user_chat_keys(id),
  ADD COLUMN IF NOT EXISTS content_original_encrypted text,
  ADD COLUMN IF NOT EXISTS content_original_nonce text,
  ADD COLUMN IF NOT EXISTS content_translated_encrypted text,
  ADD COLUMN IF NOT EXISTS content_translated_nonce text,
  ADD COLUMN IF NOT EXISTS wrapped_keys jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS detected_source_language text,
  ADD COLUMN IF NOT EXISTS translated_target_language text;

-- Generated column: translation_capable = wrapped_keys has 'supabase'
ALTER TABLE public.chat_messages
  DROP COLUMN IF EXISTS translation_capable;

ALTER TABLE public.chat_messages
  ADD COLUMN translation_capable boolean
    GENERATED ALWAYS AS ((wrapped_keys ? 'supabase'::text)) STORED;

CREATE INDEX IF NOT EXISTS idx_chat_messages_encryption_scheme
  ON public.chat_messages(encryption_scheme);

CREATE INDEX IF NOT EXISTS idx_chat_messages_translation_capable
  ON public.chat_messages(translation_capable)
  WHERE translation_capable = true;

CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_key_id
  ON public.chat_messages(sender_key_id);

CREATE INDEX IF NOT EXISTS idx_chat_messages_recipient_key_id
  ON public.chat_messages(recipient_key_id);

-- Constraint: v1 rows must not have content in legacy plaintext columns
ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_messages_v1_no_plaintext_chk;
ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_v1_no_plaintext_chk
CHECK (
  encryption_scheme != 'v1'
  OR (content_original IS NULL AND content_translated IS NULL)
);

-- ============================================================
-- 4. RPC: create_or_replace_chat_key_wrapper
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_or_replace_chat_key_wrapper(
  p_user_chat_key_id uuid,
  p_wrapper_type text,
  p_kdf text,
  p_kdf_iterations integer,
  p_kdf_salt text,
  p_wrap_alg text,
  p_wrap_nonce text,
  p_encrypted_private_key text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_key_user_id uuid;
  v_existing_id uuid;
  v_result_id uuid;
BEGIN
  -- Verify the key belongs to the authenticated user
  SELECT user_id INTO v_key_user_id
  FROM public.user_chat_keys
  WHERE id = p_user_chat_key_id;

  IF v_key_user_id IS NULL THEN
    RAISE EXCEPTION 'Chat key not found';
  END IF;

  IF v_key_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to modify this key';
  END IF;

  -- Upsert wrapper
  INSERT INTO public.user_chat_key_wrappers (
    user_chat_key_id, user_id, wrapper_type, kdf, kdf_iterations,
    kdf_salt, wrap_alg, wrap_nonce, encrypted_private_key
  ) VALUES (
    p_user_chat_key_id, auth.uid(), p_wrapper_type, p_kdf, p_kdf_iterations,
    p_kdf_salt, p_wrap_alg, p_wrap_nonce, p_encrypted_private_key
  )
  ON CONFLICT (user_chat_key_id, wrapper_type)
  DO UPDATE SET
    kdf = EXCLUDED.kdf,
    kdf_iterations = EXCLUDED.kdf_iterations,
    kdf_salt = EXCLUDED.kdf_salt,
    wrap_alg = EXCLUDED.wrap_alg,
    wrap_nonce = EXCLUDED.wrap_nonce,
    encrypted_private_key = EXCLUDED.encrypted_private_key,
    updated_at = now()
  RETURNING id INTO v_result_id;

  RETURN v_result_id;
END;
$$;

-- ============================================================
-- 5. RPC: get_peer_chat_public_keys
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_peer_chat_public_keys(
  p_key_ids uuid[]
) RETURNS TABLE (
  id uuid,
  user_id uuid,
  key_version integer,
  public_key text,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT k.id, k.user_id, k.key_version, k.public_key, k.status
  FROM public.user_chat_keys k
  WHERE k.id = ANY(p_key_ids)
    AND (
      k.user_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.matches m
        WHERE (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
          AND (m.user1_id = k.user_id OR m.user2_id = k.user_id)
      )
    );
END;
$$;

-- ============================================================
-- 6. RPC: replace_lost_chat_key
-- ============================================================
CREATE OR REPLACE FUNCTION public.replace_lost_chat_key(
  p_lost_key_id uuid,
  p_new_public_key text,
  p_reauth_token text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_current_max_version integer;
  v_new_key_id uuid;
BEGIN
  -- Verify the lost key belongs to the authenticated user
  SELECT user_id INTO v_user_id
  FROM public.user_chat_keys
  WHERE id = p_lost_key_id;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Lost key not found';
  END IF;

  IF v_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to replace this key';
  END IF;

  -- Get the current max key_version for this user
  SELECT COALESCE(MAX(key_version), 0) INTO v_current_max_version
  FROM public.user_chat_keys
  WHERE user_id = auth.uid();

  -- Mark old key as lost
  UPDATE public.user_chat_keys
  SET status = 'lost', retired_at = now()
  WHERE id = p_lost_key_id AND user_id = auth.uid();

  -- Insert new active key
  INSERT INTO public.user_chat_keys (
    user_id, key_version, public_key, status, activated_at
  ) VALUES (
    auth.uid(), v_current_max_version + 1, p_new_public_key, 'active', now()
  )
  RETURNING id INTO v_new_key_id;

  RETURN v_new_key_id;
END;
$$;

-- ============================================================
-- 7. RPC: get_user_active_chat_key
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_active_chat_key(
  p_user_id uuid
) RETURNS TABLE (
  id uuid,
  user_id uuid,
  key_version integer,
  public_key text,
  status text,
  created_at timestamptz,
  activated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Only allow if the requesting user is matched with p_user_id
  RETURN QUERY
  SELECT k.id, k.user_id, k.key_version, k.public_key, k.status,
         k.created_at, k.activated_at
  FROM public.user_chat_keys k
  WHERE k.user_id = p_user_id
    AND k.status = 'active'
    AND (
      k.user_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.matches m
        WHERE (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
          AND (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      )
    )
  LIMIT 1;
END;
$$;
