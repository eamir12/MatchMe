-- supabase/tests/test_add_message_replies.sql
-- Verifies that the replies migration added the column and FK constraint.
-- Exits with an error if expectations are not met.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'chat_messages' AND column_name = 'reply_to_message_id'
  ) THEN
    RAISE EXCEPTION 'Column reply_to_message_id is missing on public.chat_messages';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_chat_messages_reply_to_message'
  ) THEN
    RAISE EXCEPTION 'Constraint fk_chat_messages_reply_to_message is missing';
  END IF;
END
$$;

-- If we reach here, test passed
SELECT 'ok' AS test_status;
