-- Revert to a simpler approach: use SECURITY DEFINER with explicit vault access
DROP TRIGGER IF EXISTS auto_translate_on_insert ON chat_messages;

CREATE OR REPLACE FUNCTION public.auto_translate_message_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_target_language TEXT;
  v_translation_enabled BOOLEAN;
  v_deepl_lang_code TEXT;
  v_api_key TEXT;
  v_error_msg TEXT;
  v_http_response RECORD;
  v_translated_text TEXT;
BEGIN
  -- Early exit: don't translate if content_translated is already set
  IF NEW.content_translated IS NOT NULL AND NEW.content_translated != '' AND NEW.content_translated != 'null' THEN
    RETURN NEW;
  END IF;

  -- Get translation settings from the chat
  BEGIN
    SELECT translation_enabled, translation_language
    INTO v_translation_enabled, v_target_language
    FROM chats
    WHERE match_id = NEW.match_id
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;

  -- Exit if translation not enabled or no language set
  IF NOT COALESCE(v_translation_enabled, false) OR v_target_language IS NULL OR v_target_language = '' THEN
    RETURN NEW;
  END IF;

  -- Skip very short messages
  IF LENGTH(TRIM(NEW.content_original)) < 2 THEN
    RETURN NEW;
  END IF;

  -- Get API key from vault
  BEGIN
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets
    WHERE name = 'DEEPL_API_KEY'
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;
  
  IF v_api_key IS NULL OR v_api_key = '' THEN
    RETURN NEW;
  END IF;

  v_deepl_lang_code := UPPER(v_target_language);

  BEGIN
    -- Make HTTP POST request to DeepL API
    SELECT * INTO v_http_response
    FROM http_post(
      'https://api-free.deepl.com/v1/translate',
      jsonb_build_object(
        'text', ARRAY[NEW.content_original],
        'target_lang', v_deepl_lang_code,
        'auth_key', v_api_key
      )::text,
      'application/json'
    );

    -- Parse response if successful
    IF v_http_response.status = 200 THEN
      v_translated_text := (v_http_response.content::jsonb -> 'translations' -> 0 ->> 'text');
      
      IF v_translated_text IS NOT NULL AND v_translated_text != '' THEN
        NEW.content_translated := v_translated_text;
      END IF;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- Non-blocking: if translation fails, message still inserts
  END;

  RETURN NEW;
END;
$$;

CREATE TRIGGER auto_translate_on_insert
BEFORE INSERT ON chat_messages
FOR EACH ROW
EXECUTE FUNCTION auto_translate_message_on_insert();
