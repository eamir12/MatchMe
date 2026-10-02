-- Add 'auth_private_key' wrapper type.
-- Stores the user's chat private key encrypted with a key derived from the
-- user's UUID (immutable). This gives the system a reliable way to recover
-- the private key on web, where FlutterSecureStorage is not durable, without
-- requiring user interaction and without rotating the key.

ALTER TABLE public.user_chat_key_wrappers
  DROP CONSTRAINT IF EXISTS user_chat_key_wrappers_wrapper_type_check;

ALTER TABLE public.user_chat_key_wrappers
  ADD CONSTRAINT user_chat_key_wrappers_wrapper_type_check
  CHECK (wrapper_type IN ('recovery_key', 'password', 'auth_crk', 'auth_private_key'));
