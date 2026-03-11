-- Alternative approach: Store API key in a config table instead of vault
-- This avoids vault permission issues entirely

DROP TRIGGER IF EXISTS auto_translate_on_insert ON chat_messages;
DROP FUNCTION IF EXISTS public.auto_translate_message_on_insert();

-- Create config table if it doesn't exist
CREATE TABLE IF NOT EXISTS app_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Ensure the app_config table is accessible
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

-- Allow service_role to manage it
CREATE POLICY "Service role can access app_config" ON app_config
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Function to translate messages
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
BEGIN
  -- Skip if already translated
  IF NEW.content_translated IS NOT NULL AND NEW.content_translated != '' THEN
    RETURN NEW;
  END IF;

  -- Get chat translation settings
  SELECT translation_enabled, translation_language
  INTO v_translation_enabled, v_target_language
  FROM chats
  WHERE match_id = NEW.match_id
  LIMIT 1;

  -- Check if translation is enabled
  IF NOT COALESCE(v_translation_enabled, false) OR v_target_language IS NULL THEN
    RETURN NEW;
  END IF;

  -- Skip very short messages
  IF LENGTH(TRIM(NEW.content_original)) < 2 THEN
    RETURN NEW;
  END IF;

  -- Get API key from config table
  SELECT value INTO v_api_key FROM app_config WHERE key = 'deepl_api_key' LIMIT 1;

  IF v_api_key IS NULL OR v_api_key = '' THEN
    RETURN NEW;
  END IF;

  v_deepl_lang_code := UPPER(v_target_language);

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

    IF v_http_response.status = 200 THEN
      v_translated_text := (v_http_response.content::jsonb -> 'translations' -> 0 ->> 'text');
      
      IF v_translated_text IS NOT NULL AND v_translated_text != '' THEN
        NEW.content_translated := v_translated_text;
      END IF;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- Silently fail - message still inserts
    NULL;
  END;

  RETURN NEW;
END;
$$;

-- Create trigger
CREATE TRIGGER auto_translate_on_insert
BEFORE INSERT ON chat_messages
FOR EACH ROW
EXECUTE FUNCTION auto_translate_message_on_insert();
