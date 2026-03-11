-- Set the DeepL API key for the translation trigger
-- This requires you to have a DeepL API account and key

-- IMPORTANT: You need to manually set this value with your actual DeepL API key
-- To do this:
-- 1. Go to your Supabase Dashboard
-- 2. Go to Project Settings > Database > Configuration
-- 3. Add a new config parameter: deepl_api_key = YOUR_API_KEY_HERE
--
-- OR run this in your Supabase SQL Editor and replace YOUR_API_KEY_HERE:
-- SELECT set_config('app.deepl_api_key', 'YOUR_API_KEY_HERE', false);

-- For testing without an API key, you can temporarily disable the trigger:
-- DROP TRIGGER auto_translate_on_insert ON chat_messages;

-- And re-enable it later:
-- CREATE TRIGGER auto_translate_on_insert
-- BEFORE INSERT ON chat_messages
-- FOR EACH ROW
-- EXECUTE FUNCTION auto_translate_message_on_insert();
