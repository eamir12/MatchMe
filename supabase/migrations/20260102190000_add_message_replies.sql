-- supabase/migrations/20260102190000_add_message_replies.sql
-- Add reply_to_message_id to chat_messages so messages can reference a message they reply to.
BEGIN;

ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS reply_to_message_id uuid NULL;

-- Add a foreign key reference to the same table; on delete of the replied-to message, set null
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_chat_messages_reply_to_message'
  ) THEN
    EXECUTE 'ALTER TABLE public.chat_messages ADD CONSTRAINT fk_chat_messages_reply_to_message FOREIGN KEY (reply_to_message_id) REFERENCES public.chat_messages(id) ON DELETE SET NULL';
  END IF;
END
$$;

COMMIT;

-- Grant privileges (if necessary) to authenticated role for selecting/inserting reply references
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO anon;