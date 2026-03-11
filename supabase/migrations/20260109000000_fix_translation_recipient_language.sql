-- Fix auto-translation trigger to translate to RECIPIENT's language, not sender's language
-- This ensures that incoming messages are translated to the correct language for each user

DROP TRIGGER IF EXISTS auto_translate_on_insert ON chat_messages;
DROP FUNCTION IF EXISTS public.auto_translate_message_on_insert();

CREATE OR REPLACE FUNCTION public.auto_translate_message_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_recipient_id UUID;
  v_target_language TEXT;
  v_translation_enabled BOOLEAN;
  v_deepl_lang_code TEXT;
  v_api_key TEXT;
  v_http_response RECORD;
  v_translated_text TEXT;
  v_error_msg TEXT;
  v_match RECORD;
BEGIN
  RAISE NOTICE '[AUTO_TRANSLATE] Trigger fired for message % from sender %', NEW.id, NEW.sender_id;

  -- Skip if already translated
  IF NEW.content_translated IS NOT NULL AND NEW.content_translated != '' AND NEW.content_translated != 'null' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Message % already has translation, skipping', NEW.id;
    RETURN NEW;
  END IF;

  -- Skip very short messages
  IF LENGTH(TRIM(NEW.content_original)) < 2 THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Message too short, skipping';
    RETURN NEW;
  END IF;

  -- Get the match to determine who the recipient is
  BEGIN
    SELECT user1_id, user2_id
    INTO v_match
    FROM matches
    WHERE id = NEW.match_id
    LIMIT 1;
    
    IF v_match IS NULL THEN
      RAISE NOTICE '[AUTO_TRANSLATE] Match not found for match_id %', NEW.match_id;
      RETURN NEW;
    END IF;

    -- Determine the recipient (the OTHER user, not the sender)
    IF NEW.sender_id = v_match.user1_id THEN
      v_recipient_id := v_match.user2_id;
    ELSE
      v_recipient_id := v_match.user1_id;
    END IF;

    RAISE NOTICE '[AUTO_TRANSLATE] Sender: %, Recipient: %', NEW.sender_id, v_recipient_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Error fetching match: %', SQLERRM;
    RETURN NEW;
  END;

  -- Get RECIPIENT's chat translation settings (not sender's!)
  BEGIN
    SELECT translation_enabled, translation_language
    INTO v_translation_enabled, v_target_language
    FROM chats
    WHERE match_id = NEW.match_id
      AND user_id = v_recipient_id
    LIMIT 1;
    
    RAISE NOTICE '[AUTO_TRANSLATE] Recipient chat - enabled: %, language: %', v_translation_enabled, v_target_language;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Error fetching recipient chat: %', SQLERRM;
    RETURN NEW;
  END;

  -- Check if recipient has translation enabled
  IF NOT COALESCE(v_translation_enabled, false) THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Recipient has translation disabled';
    RETURN NEW;
  END IF;

  IF v_target_language IS NULL OR v_target_language = '' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Recipient has no target language set';
    RETURN NEW;
  END IF;

  -- Get API key from config table
  BEGIN
    SELECT value INTO v_api_key FROM app_config WHERE key = 'deepl_api_key' LIMIT 1;
    
    RAISE NOTICE '[AUTO_TRANSLATE] API key present: %', v_api_key IS NOT NULL AND v_api_key != '';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[AUTO_TRANSLATE] Error fetching API key: %', SQLERRM;
    RETURN NEW;
  END;

  IF v_api_key IS NULL OR v_api_key = '' OR v_api_key = 'YOUR_DEEPL_API_KEY_HERE' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] No valid DeepL API key configured';
    RETURN NEW;
  END IF;

  v_deepl_lang_code := UPPER(v_target_language);

  RAISE NOTICE '[AUTO_TRANSLATE] Calling DeepL to translate to recipient language: %', v_deepl_lang_code;

  -- Call DeepL API
  BEGIN
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

    IF v_http_response.status = 200 THEN
      v_translated_text := (v_http_response.content::jsonb -> 'translations' -> 0 ->> 'text');
      
      RAISE NOTICE '[AUTO_TRANSLATE] Translated text: %', v_translated_text;
      
      IF v_translated_text IS NOT NULL AND v_translated_text != '' THEN
        NEW.content_translated := v_translated_text;
        RAISE NOTICE '[AUTO_TRANSLATE] SUCCESS: Message % translated to % for recipient %', NEW.id, v_deepl_lang_code, v_recipient_id;
      ELSE
        RAISE NOTICE '[AUTO_TRANSLATE] Translation response was empty';
      END IF;
    ELSE
      RAISE NOTICE '[AUTO_TRANSLATE] DeepL error status % with content: %', v_http_response.status, v_http_response.content;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_error_msg := SQLERRM;
    RAISE NOTICE '[AUTO_TRANSLATE] ERROR calling DeepL: %', v_error_msg;
  END;

  RETURN NEW;
END;
$$;

-- Recreate the trigger
CREATE TRIGGER auto_translate_on_insert
BEFORE INSERT ON chat_messages
FOR EACH ROW
EXECUTE FUNCTION auto_translate_message_on_insert();

COMMENT ON FUNCTION public.auto_translate_message_on_insert() IS 
'Automatically translates incoming chat messages to the RECIPIENT''s preferred language. 
The function identifies the recipient by querying the matches table to determine who the 
other user is (not the sender), then fetches that user''s chat translation settings.';
