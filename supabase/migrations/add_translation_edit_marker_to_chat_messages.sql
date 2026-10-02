-- Bind stored translations to the content version they were made for.
--
-- The translation AAD binds the target language but NOT the original content,
-- so a pre-edit encrypted translation still decrypts after an edit and would
-- be served (and skipped by translate-proxy) as if it matched the new text.
-- `translated_source_edited_at` records the row's `edited_at` value at the
-- moment of translation (NULL for never-edited messages). translate-proxy
-- skips a stored translation only when this marker still equals the row's
-- current `edited_at` (NULL-safe); any edit invalidates it and forces a
-- single regeneration. This is pure metadata already visible to both match
-- participants — no plaintext-derived data, nothing to brute-force.
--
-- No backfill is needed: rows translated before this column existed carry a
-- NULL marker, which matches a NULL `edited_at` (never edited, translation
-- is current) and mismatches any set `edited_at` (edited, retranslate once
-- on next view, then the marker is stamped).

ALTER TABLE IF EXISTS public.chat_messages
ADD COLUMN IF NOT EXISTS translated_source_edited_at timestamp with time zone;

-- Canonical edit RPC: an edit invalidates the translation made for the
-- previous content, so clear the stored payload AND its version marker.
-- The next view retranslates exactly once and restamps the marker.
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
    translated_source_edited_at = NULL,
    edited_at = now()
  WHERE id = p_message_id
    AND sender_id = auth.uid()
  RETURNING *;
END;
$$;

GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, text, jsonb, text, text, uuid) TO authenticated;
