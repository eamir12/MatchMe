-- Create a log table to diagnose the trigger
CREATE TABLE IF NOT EXISTS translation_trigger_logs (
  id BIGSERIAL PRIMARY KEY,
  message_id UUID,
  event TEXT,
  details JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Allow anyone to read logs
ALTER TABLE translation_trigger_logs DISABLE ROW LEVEL SECURITY;

-- Update the trigger to log everything
DROP TRIGGER IF EXISTS auto_translate_on_insert ON chat_messages;
DROP FUNCTION IF EXISTS public.auto_translate_message_on_insert();

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
  v_http_response RECORD;
  v_translated_text TEXT;
  v_error_msg TEXT;
BEGIN
  -- Log: Trigger fired
  INSERT INTO translation_trigger_logs (message_id, event, details)
  VALUES (NEW.id, 'TRIGGER_FIRED', jsonb_build_object(
    'content_original', NEW.content_original,
    'match_id', NEW.match_id
  ));

  -- Skip if already translated
  IF NEW.content_translated IS NOT NULL AND NEW.content_translated != '' THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'SKIP_ALREADY_TRANSLATED', jsonb_build_object(
      'content_translated', NEW.content_translated
    ));
    RETURN NEW;
  END IF;

  -- Get chat translation settings
  BEGIN
    SELECT translation_enabled, translation_language
    INTO v_translation_enabled, v_target_language
    FROM chats
    WHERE match_id = NEW.match_id
    LIMIT 1;
    
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'CHAT_SETTINGS_FETCHED', jsonb_build_object(
      'translation_enabled', v_translation_enabled,
      'translation_language', v_target_language
    ));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'ERROR_FETCH_CHAT', jsonb_build_object(
      'error', SQLERRM
    ));
    RETURN NEW;
  END;

  -- Check if translation is enabled
  IF NOT COALESCE(v_translation_enabled, false) THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'SKIP_TRANSLATION_DISABLED', null);
    RETURN NEW;
  END IF;

  IF v_target_language IS NULL OR v_target_language = '' THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'SKIP_NO_LANGUAGE', null);
    RETURN NEW;
  END IF;

  -- Skip very short messages
  IF LENGTH(TRIM(NEW.content_original)) < 2 THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'SKIP_TOO_SHORT', null);
    RETURN NEW;
  END IF;

  -- Get API key from config table
  BEGIN
    SELECT value INTO v_api_key FROM app_config WHERE key = 'deepl_api_key' LIMIT 1;
    
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'API_KEY_FETCHED', jsonb_build_object(
      'api_key_exists', v_api_key IS NOT NULL,
      'api_key_length', CASE WHEN v_api_key IS NOT NULL THEN LENGTH(v_api_key) ELSE 0 END
    ));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'ERROR_FETCH_API_KEY', jsonb_build_object(
      'error', SQLERRM
    ));
    RETURN NEW;
  END;

  IF v_api_key IS NULL OR v_api_key = '' THEN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'SKIP_NO_API_KEY', null);
    RETURN NEW;
  END IF;

  v_deepl_lang_code := UPPER(v_target_language);

  -- Call DeepL API
  BEGIN
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'CALLING_DEEPL', jsonb_build_object(
      'text', NEW.content_original,
      'target_lang', v_deepl_lang_code
    ));

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

    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'DEEPL_RESPONSE', jsonb_build_object(
      'status', v_http_response.status,
      'content', v_http_response.content
    ));

    IF v_http_response.status = 200 THEN
      v_translated_text := (v_http_response.content::jsonb -> 'translations' -> 0 ->> 'text');
      
      INSERT INTO translation_trigger_logs (message_id, event, details)
      VALUES (NEW.id, 'TRANSLATION_EXTRACTED', jsonb_build_object(
        'translated_text', v_translated_text
      ));
      
      IF v_translated_text IS NOT NULL AND v_translated_text != '' THEN
        NEW.content_translated := v_translated_text;
        INSERT INTO translation_trigger_logs (message_id, event, details)
        VALUES (NEW.id, 'SUCCESS', jsonb_build_object(
          'translated_text', v_translated_text
        ));
      END IF;
    ELSE
      INSERT INTO translation_trigger_logs (message_id, event, details)
      VALUES (NEW.id, 'ERROR_DEEPL_STATUS', jsonb_build_object(
        'status', v_http_response.status
      ));
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_error_msg := SQLERRM;
    INSERT INTO translation_trigger_logs (message_id, event, details)
    VALUES (NEW.id, 'ERROR_DEEPL_CALL', jsonb_build_object(
      'error', v_error_msg
    ));
  END;

  RETURN NEW;
END;
$$;

CREATE TRIGGER auto_translate_on_insert
BEFORE INSERT ON chat_messages
FOR EACH ROW
EXECUTE FUNCTION auto_translate_message_on_insert();
