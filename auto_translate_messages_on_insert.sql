-- Create a trigger to automatically translate messages when they're inserted
-- This ensures content_translated is populated immediately, so background notifications can show translated messages

CREATE OR REPLACE FUNCTION public.auto_translate_message()
RETURNS TRIGGER AS $$
DECLARE
  v_target_language TEXT;
  v_translation_result JSONB;
BEGIN
  -- Only translate if translation is enabled for this chat
  -- and content_translated is not already set
  IF NEW.content_translated IS NULL OR NEW.content_translated = 'null' THEN
    -- Get the target translation language for this chat
    SELECT translation_language INTO v_target_language
    FROM public.chats
    WHERE id = NEW.match_id
      AND translation_enabled = true
    LIMIT 1;
    
    IF v_target_language IS NOT NULL THEN
      -- Call the translate-proxy edge function to translate the message
      -- This will translate and save synchronously
      BEGIN
        v_translation_result := (
          WITH translate_call AS (
            SELECT
              http_post(
                'https://vazkmvrbshxwyodentng.supabase.co/functions/v1/translate-proxy',
                jsonb_build_object(
                  'text', NEW.content_original,
                  'target_language', v_target_language
                )::text,
                'application/json',
                ARRAY[
                  http_header('Authorization', 'Bearer ' || current_setting('app.jwt_token', true)),
                  http_header('Content-Type', 'application/json')
                ]
              ) as response
            )
            SELECT (response).content::jsonb FROM translate_call
        );
        
        -- Extract translated text from response
        IF v_translation_result IS NOT NULL THEN
          NEW.content_translated := v_translation_result->>'translatedText';
        END IF;
      EXCEPTION WHEN OTHERS THEN
        -- If translation fails, leave content_translated as NULL
        -- The original message will be shown in notifications
        NULL;
      END;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop trigger if it exists
DROP TRIGGER IF EXISTS trg_auto_translate_message ON public.chat_messages;

-- Create trigger on INSERT
CREATE TRIGGER trg_auto_translate_message
BEFORE INSERT ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.auto_translate_message();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION public.auto_translate_message() TO postgres;
