-- Add 'auth_crk' wrapper type to store CRK encrypted with user's auth credentials
-- This allows automatic recovery of the CRK after login without user intervention

-- Update the CHECK constraint to include 'auth_crk' wrapper type
ALTER TABLE public.user_chat_key_wrappers
  DROP CONSTRAINT IF EXISTS user_chat_key_wrappers_wrapper_type_check;

ALTER TABLE public.user_chat_key_wrappers
  ADD CONSTRAINT user_chat_key_wrappers_wrapper_type_check
  CHECK (wrapper_type IN ('recovery_key', 'password', 'auth_crk'));

-- Add a new table to store encrypted CRK (Chat Recovery Key)
-- The CRK is encrypted using a key derived from the user's auth session
CREATE TABLE IF NOT EXISTS public.user_chat_crk_wrappers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  user_chat_key_id uuid NOT NULL REFERENCES public.user_chat_keys(id) ON DELETE CASCADE,
  kdf text NOT NULL DEFAULT 'HKDF-SHA256',
  kdf_salt text NOT NULL,
  wrap_alg text NOT NULL DEFAULT 'AES-256-GCM',
  wrap_nonce text NOT NULL,
  encrypted_crk text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, user_chat_key_id)
);

CREATE INDEX IF NOT EXISTS idx_user_chat_crk_wrappers_user_id
  ON public.user_chat_crk_wrappers(user_id);

CREATE INDEX IF NOT EXISTS idx_user_chat_crk_wrappers_key_id
  ON public.user_chat_crk_wrappers(user_chat_key_id);

-- RLS policies: users can only access their own CRK wrappers
ALTER TABLE public.user_chat_crk_wrappers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_chat_crk_wrappers_select_own ON public.user_chat_crk_wrappers;
CREATE POLICY user_chat_crk_wrappers_select_own
  ON public.user_chat_crk_wrappers
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS user_chat_crk_wrappers_insert_own ON public.user_chat_crk_wrappers;
CREATE POLICY user_chat_crk_wrappers_insert_own
  ON public.user_chat_crk_wrappers
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS user_chat_crk_wrappers_update_own ON public.user_chat_crk_wrappers;
CREATE POLICY user_chat_crk_wrappers_update_own
  ON public.user_chat_crk_wrappers
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS user_chat_crk_wrappers_delete_own ON public.user_chat_crk_wrappers;
CREATE POLICY user_chat_crk_wrappers_delete_own
  ON public.user_chat_crk_wrappers
  FOR DELETE
  USING (auth.uid() = user_id);
