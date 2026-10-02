-- Ensure edit RPCs are compatible with the current chat_messages schema.
-- Legacy plaintext columns were removed; edits must be encrypted.

CREATE OR REPLACE FUNCTION public.edit_chat_message(
  p_message_id uuid,
  p_new_content text
)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.chat_messages
  SET
    content_original_encrypted = p_new_content,
    content_original_nonce = NULL,
    encryption_scheme = 'v1',
    wrapped_keys = '{}'::jsonb,
    content_translated_encrypted = NULL,
    content_translated_nonce = NULL,
    translated_target_language = NULL,
    edited_at = now()
  WHERE id = p_message_id
    AND sender_id = auth.uid()
  RETURNING *;
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_chat_message(
  p_message_id uuid,
  p_new_content text,
  p_user_id uuid
)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT * FROM public.edit_chat_message(p_message_id, p_new_content);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_message(
  p_message_id uuid,
  p_new_content text,
  p_user_id uuid
)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT * FROM public.edit_chat_message(p_message_id, p_new_content);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_message(
  p_message_id uuid,
  p_user_id uuid,
  p_new_content text
)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT * FROM public.edit_chat_message(p_message_id, p_new_content);
END;
$$;
