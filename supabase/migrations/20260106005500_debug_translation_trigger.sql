-- Fix: Add logging back to debug the issue
DROP TRIGGER IF EXISTS auto_translate_on_insert ON chat_messages;

CREATE OR REPLACE FUNCTION public.auto_translate_message_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
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
    
    RAISE NOTICE '[AUTO_TRANSLATE] Chat % - enabled: %, language: %', NEW.match_id, v_translation_enabled, v_target_language;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Chat not found for match_id %', NEW.match_id;
    RETURN NEW;
  END;

  -- Exit if translation not enabled or no language set
  IF NOT COALESCE(v_translation_enabled, false) THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Translation not enabled';
    RETURN NEW;
  END IF;
  
  IF v_target_language IS NULL OR v_target_language = '' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] No target language set';
    RETURN NEW;
  END IF;

  -- Skip very short messages
  IF LENGTH(TRIM(NEW.content_original)) < 2 THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Message too short';
    RETURN NEW;
  END IF;

  v_deepl_lang_code := UPPER(v_target_language);

  -- Get API key from vault
  BEGIN
    RAISE NOTICE '[AUTO_TRANSLATE] Attempting to read from vault';
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets
    WHERE name = 'DEEPL_API_KEY'
    LIMIT 1;
    
    IF v_api_key IS NOT NULL THEN
      RAISE NOTICE '[AUTO_TRANSLATE] API key found, length: %', LENGTH(v_api_key);
    ELSE
      RAISE NOTICE '[AUTO_TRANSLATE] API key is NULL';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_error_msg := SQLERRM;
    RAISE NOTICE '[AUTO_TRANSLATE] Vault error: %', v_error_msg;
    RETURN NEW;
  END;
  
  IF v_api_key IS NULL OR v_api_key = '' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] No valid API key';
    RETURN NEW;
  END IF;

  RAISE NOTICE '[AUTO_TRANSLATE] Calling DeepL for: %, target: %', NEW.content_original, v_deepl_lang_code;

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

    RAISE NOTICE '[AUTO_TRANSLATE] DeepL response status: %', v_http_response.status;

    -- Parse response if successful
    IF v_http_response.status = 200 THEN
      v_translated_text := (v_http_response.content::jsonb -> 'translations' -> 0 ->> 'text');
      
      RAISE NOTICE '[AUTO_TRANSLATE] Translated to: %', v_translated_text;
      
      IF v_translated_text IS NOT NULL AND v_translated_text != '' THEN
        NEW.content_translated := v_translated_text;
        RAISE NOTICE '[AUTO_TRANSLATE] SUCCESS: Message translated';
      END IF;
    ELSE
      RAISE NOTICE '[AUTO_TRANSLATE] DeepL error status: %, body: %', v_http_response.status, v_http_response.content;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_error_msg := SQLERRM;
    RAISE NOTICE '[AUTO_TRANSLATE] HTTP error: %', v_error_msg;
  END;

  RETURN NEW;
END;
$$;

CREATE TRIGGER auto_translate_on_insert
BEFORE INSERT ON chat_messages
FOR EACH ROW
EXECUTE FUNCTION auto_translate_message_on_insert();
