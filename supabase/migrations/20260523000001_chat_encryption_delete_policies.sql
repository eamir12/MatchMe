-- Add missing DELETE RLS policies for chat encryption tables.
-- The original migration (20260523000000) created SELECT/INSERT/UPDATE but not DELETE,
-- which caused `deleteActiveKey()` in `ChatKeyService` to silently fail, leaving
-- zombie keys that block fresh `setupEncryption()` calls (unique constraint violation).

-- ============================================================
-- 1. DELETE policy for user_chat_keys
-- ============================================================
DROP POLICY IF EXISTS user_chat_keys_delete_own ON public.user_chat_keys;
CREATE POLICY user_chat_keys_delete_own
  ON public.user_chat_keys
  FOR DELETE
  USING (auth.uid() = user_id);

-- ============================================================
-- 2. DELETE policy for user_chat_key_wrappers
-- ============================================================
DROP POLICY IF EXISTS user_chat_key_wrappers_delete_own ON public.user_chat_key_wrappers;
CREATE POLICY user_chat_key_wrappers_delete_own
  ON public.user_chat_key_wrappers
  FOR DELETE
  USING (auth.uid() = user_id);
