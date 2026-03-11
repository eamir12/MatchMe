-- Drop ALL known policies on chat_messages to ensure a clean slate
DROP POLICY IF EXISTS "Users can insert messages for their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can view messages for their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can update their own messages" ON chat_messages;
DROP POLICY IF EXISTS "Users can update messages in their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can view messages in their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can send messages in their matches" ON chat_messages;
DROP POLICY IF EXISTS "Enable delete for service role" ON chat_messages;
DROP POLICY IF EXISTS "Users can insert their own messages" ON chat_messages;
DROP POLICY IF EXISTS "Users can read messages from their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can delete their own messages" ON chat_messages;

-- Re-create the comprehensive policies
-- 1. INSERT: Users can insert messages if they are the sender AND the match belongs to them
CREATE POLICY "Users can insert messages for their matches"
ON chat_messages
FOR INSERT
WITH CHECK (
    auth.uid() = sender_id
    AND EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
);

-- 2. SELECT: Users can view messages if they are part of the match
CREATE POLICY "Users can view messages for their matches"
ON chat_messages
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
);

-- 3. UPDATE: Users can update messages in their matches (for translations and editing)
CREATE POLICY "Users can update messages in their matches"
ON chat_messages
FOR UPDATE
USING (
    EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
        AND (m.user1_id = auth.uid() OR m.user2_id = auth.uid())
    )
);

-- 4. DELETE: Users can delete their own messages (optional, but good to have)
CREATE POLICY "Users can delete their own messages"
ON chat_messages
FOR DELETE
USING (auth.uid() = sender_id);

-- Ensure RLS is enabled
ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

-- Grant permissions again just in case
GRANT ALL ON chat_messages TO authenticated;
GRANT ALL ON chat_messages TO anon;
