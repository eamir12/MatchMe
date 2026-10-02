-- Require encryption in edit RPC — plaintext is never allowed to be saved.
-- The client must encrypt the new content and pass the encryption fields.
-- The RPC validates encryption_scheme = 'v1' and rejects anything else.

CREATE OR REPLACE FUNCTION public.edit_chat_message(
  p_message_id uuid,
  p_new_content text,
  p_encryption_scheme text,
  p_content_original_nonce text,
  p_wrapped_keys jsonb,
  p_sender_key_id text,
  p_recipient_key_id text,
  p_recipient_id uuid
)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_encryption_scheme IS DISTINCT FROM 'v1' THEN
    RAISE EXCEPTION 'plaintext edits are not allowed; encryption_scheme must be v1';
  END IF;

  RETURN QUERY
  UPDATE public.chat_messages
  SET
    content_original_encrypted = p_new_content,
    content_original_nonce = p_content_original_nonce,
    encryption_scheme = p_encryption_scheme,
    wrapped_keys = p_wrapped_keys,
    sender_key_id = p_sender_key_id,
    recipient_key_id = p_recipient_key_id,
    recipient_id = p_recipient_id,
    content_translated_encrypted = NULL,
    content_translated_nonce = NULL,
    translated_target_language = NULL,
    edited_at = now()
  WHERE id = p_message_id
    AND sender_id = auth.uid()
  RETURNING *;
END;
$$;
