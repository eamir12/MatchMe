-- Test and fix vault access for translation trigger
-- This version includes better error handling and logging for vault access

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
  RAISE NOTICE '[AUTO_TRANSLATE] Trigger fired for message %', NEW.id;

  -- Early exit: don't translate if content_translated is already set
  IF NEW.content_translated IS NOT NULL AND NEW.content_translated != '' AND NEW.content_translated != 'null' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Message % already has translation, skipping', NEW.id;
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

  -- Exit if translation not enabled
  IF NOT COALESCE(v_translation_enabled, false) THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Translation not enabled for chat %', NEW.match_id;
    RETURN NEW;
  END IF;
  
  IF v_target_language IS NULL OR v_target_language = '' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] No target language for chat %', NEW.match_id;
    RETURN NEW;
  END IF;

  -- Skip very short messages
  IF LENGTH(TRIM(NEW.content_original)) < 2 THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Message too short, skipping';
    RETURN NEW;
  END IF;

  -- Try to get API key from vault
  BEGIN
    RAISE NOTICE '[AUTO_TRANSLATE] Attempting to read from vault.decrypted_secrets';
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets
    WHERE name = 'DEEPL_API_KEY'
    LIMIT 1;
    
    IF v_api_key IS NOT NULL THEN
      RAISE NOTICE '[AUTO_TRANSLATE] Successfully retrieved API key from vault';
    ELSE
      RAISE NOTICE '[AUTO_TRANSLATE] Vault query returned NULL';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_error_msg := SQLERRM;
    RAISE NOTICE '[AUTO_TRANSLATE] Failed to read from vault: %', v_error_msg;
  END;
  
  -- If still no API key, return
  IF v_api_key IS NULL OR v_api_key = '' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] No valid DeepL API key available';
    RETURN NEW;
  END IF;

  v_deepl_lang_code := UPPER(v_target_language);

  RAISE NOTICE '[AUTO_TRANSLATE] Calling DeepL for text: %, target lang: %', NEW.content_original, v_deepl_lang_code;

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
      
      RAISE NOTICE '[AUTO_TRANSLATE] Translated text: %', v_translated_text;
      
      IF v_translated_text IS NOT NULL AND v_translated_text != '' THEN
        NEW.content_translated := v_translated_text;
        RAISE NOTICE '[AUTO_TRANSLATE] SUCCESS: Message % translated to %', NEW.id, v_deepl_lang_code;
      ELSE
        RAISE NOTICE '[AUTO_TRANSLATE] Translation response was empty';
      END IF;
    ELSE
      RAISE NOTICE '[AUTO_TRANSLATE] DeepL error status % with content: %', v_http_response.status, v_http_response.content;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_error_msg := SQLERRM;
    RAISE NOTICE '[AUTO_TRANSLATE] DeepL HTTP ERROR: %', v_error_msg;
  END;

  RETURN NEW;
END;
$$;
