-- Ensure canonical edit_chat_message RPC exists
-- Idempotent: safe to run multiple times across environments.

-- Add edited_at column if missing
ALTER TABLE IF EXISTS public.chat_messages
ADD COLUMN IF NOT EXISTS edited_at timestamp with time zone;

-- Create or replace the secure edit function which allows a sender to update their own message
CREATE OR REPLACE FUNCTION public.edit_chat_message(p_message_id uuid, p_new_content text)
RETURNS SETOF public.chat_messages AS $$
  UPDATE public.chat_messages
  SET content_original = p_new_content,
      edited_at = now()
  WHERE id = p_message_id
    AND sender_id = auth.uid()
  RETURNING *;
$$ LANGUAGE sql SECURITY DEFINER;

-- NOTE: SECURITY DEFINER is used intentionally here so that the function can perform the update
-- while still relying on auth.uid() for the authorization check. Ensure the function owner is a
-- trusted role (e.g., postgres or a deployment-specific role) and review RLS policies accordingly.
