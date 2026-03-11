-- Fix: Remove broken legacy trigger and function that reference the deleted upsert_user_recent_chat function

-- 1. Drop the legacy trigger on chat_messages
DROP TRIGGER IF EXISTS trg_handle_chat_message ON public.chat_messages;

-- 2. Drop the legacy function
DROP FUNCTION IF EXISTS public.handle_chat_message();

-- 3. Ensure the new trigger exists (idempotent check)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_handle_chat_message_for_chats') THEN
    CREATE TRIGGER trg_handle_chat_message_for_chats
    AFTER INSERT ON public.chat_messages
    FOR EACH ROW EXECUTE FUNCTION public.handle_chat_message_for_chats();
  END IF;
END$$;
