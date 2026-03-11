-- Create a configuration table for storing API keys and settings
CREATE TABLE IF NOT EXISTS app_config (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  key TEXT UNIQUE NOT NULL,
  value TEXT,
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS but allow service_role to manage all rows
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Only service role can access app_config"
  ON app_config
  USING (auth.role() = 'service_role');

-- Insert or update the DeepL API key
-- NOTE: Replace 'YOUR_DEEPL_API_KEY' with your actual key from Supabase Edge Functions → Secrets
INSERT INTO app_config (key, value, description)
VALUES ('deepl_api_key', 'YOUR_DEEPL_API_KEY_HERE', 'DeepL API key for message translation')
ON CONFLICT (key) DO UPDATE SET
  value = 'YOUR_DEEPL_API_KEY_HERE',
  updated_at = NOW();

-- Update the trigger to read from the config table instead of session settings
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

  -- Get API key from config table (persistent and reliable)
  SELECT value INTO v_api_key FROM app_config WHERE key = 'deepl_api_key' LIMIT 1;
  
  RAISE NOTICE '[AUTO_TRANSLATE] API key present: %', v_api_key IS NOT NULL AND v_api_key != '';
  
  -- If no API key, just return
  IF v_api_key IS NULL OR v_api_key = '' OR v_api_key = 'YOUR_DEEPL_API_KEY_HERE' THEN
    RAISE NOTICE '[AUTO_TRANSLATE] No valid DeepL API key configured';
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
    RAISE NOTICE '[AUTO_TRANSLATE] ERROR: %', v_error_msg;
  END;

  RETURN NEW;
END;
$$;
