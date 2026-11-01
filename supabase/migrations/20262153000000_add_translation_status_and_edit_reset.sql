-- Track the lifecycle of the server-side chat translation payload.
--
-- `translation_status` is diagnostics/retry metadata, not display data:
--   pending       -> translation requested / in flight
--   success       -> translated payload stored
--   same_language -> message already in the recipient's language
--   skipped       -> emoji/whitespace-only content, original is the payload
--   failed        -> translation failed; the original is stored as the
--                    translated payload so every surface can show it
--
-- Apply this migration BEFORE deploying the updated translate-proxy and the
-- updated client: the function writes these columns in the same update as the
-- payload, and the client selects `translation_status` during chat sync. A
-- pre-migration deployment would fail those writes/selects and withhold the
-- push.

ALTER TABLE IF EXISTS public.chat_messages
  ADD COLUMN IF NOT EXISTS translation_status text,
  ADD COLUMN IF NOT EXISTS translation_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS translated_at timestamp with time zone;

UPDATE public.chat_messages
SET translation_status = 'success'
WHERE translation_status IS NULL
  AND content_translated_encrypted IS NOT NULL
  AND btrim(content_translated_encrypted) <> '';

UPDATE public.chat_messages
SET translation_status = 'pending'
WHERE translation_status IS NULL
  AND translated_target_language IS NOT NULL
  AND (
    content_translated_encrypted IS NULL
    OR btrim(content_translated_encrypted) = ''
  );

CREATE INDEX IF NOT EXISTS idx_chat_messages_translation_status_failed
  ON public.chat_messages (match_id)
  WHERE translation_status = 'failed';

COMMENT ON COLUMN public.chat_messages.translation_status IS
  'pending | success | same_language | skipped | failed. NULL for legacy rows.';
COMMENT ON COLUMN public.chat_messages.translation_attempts IS
  'Number of DeepL attempts since the last edit. Reset by the edit trigger.';
COMMENT ON COLUMN public.chat_messages.translated_at IS
  'When the current translated payload was written by translate-proxy.';

-- The old plaintext trigger could never work against the v1-encrypted schema
-- (the plaintext columns no longer exist), but drop it defensively so a
-- database that still carries it cannot fire against text columns that were
-- re-added by a future migration.
DROP TRIGGER IF EXISTS auto_translate_on_insert ON public.chat_messages;
DROP FUNCTION IF EXISTS public.auto_translate_message_on_insert();

-- An edit invalidates the stored translation. The RPC already clears the
-- payload, but direct table updates (client fallback, admin tooling) must reset
-- the lifecycle too so the next batch retries instead of skipping a failed row.
CREATE OR REPLACE FUNCTION public.reset_translation_status_on_edit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.content_original_encrypted IS DISTINCT FROM OLD.content_original_encrypted THEN
    NEW.content_translated_encrypted := NULL;
    NEW.content_translated_nonce := NULL;
    NEW.translated_target_language := NULL;
    NEW.translated_source_edited_at := NULL;
    NEW.translation_status := 'pending';
    NEW.translation_attempts := 0;
    NEW.translated_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reset_translation_status_on_edit ON public.chat_messages;
CREATE TRIGGER reset_translation_status_on_edit
BEFORE UPDATE OF content_original_encrypted ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.reset_translation_status_on_edit();
