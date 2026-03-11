-- Add message editing support: store edited timestamp and provide RPC for secure edits

-- 1) Add edited_at column
ALTER TABLE IF EXISTS chat_messages
ADD COLUMN IF NOT EXISTS edited_at timestamp with time zone;

-- 2) RPC function to allow a message sender to edit their message
CREATE OR REPLACE FUNCTION edit_chat_message(p_message_id uuid, p_new_content text)
RETURNS SETOF chat_messages AS $$
  UPDATE chat_messages
  SET content_original = p_new_content, edited_at = now()
  WHERE id = p_message_id AND sender_id = auth.uid()
  RETURNING *;
$$ LANGUAGE sql;
