-- ============================================================================
-- Remove the old auto-translate trigger that causes duplicate translations
-- ============================================================================

-- Drop the old auto_translate trigger and function
DROP TRIGGER IF EXISTS auto_translate_on_insert ON public.chat_messages;
DROP FUNCTION IF EXISTS public.auto_translate_message_on_insert();

-- Verify it's gone
SELECT tgname as trigger_name
FROM pg_trigger 
WHERE tgrelid = 'public.chat_messages'::regclass 
  AND NOT tgisinternal
  AND tgname LIKE '%translate%';
