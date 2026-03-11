-- Drop existing policies to avoid conflicts
DROP POLICY IF EXISTS "Users can insert messages for their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can view messages for their matches" ON chat_messages;
DROP POLICY IF EXISTS "Users can update their own messages" ON chat_messages;

-- Create comprehensive policies for chat_messages

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

-- 3. UPDATE: Users can update their own messages (e.g. for editing)
CREATE POLICY "Users can update their own messages"
ON chat_messages
FOR UPDATE
USING (auth.uid() = sender_id)
WITH CHECK (auth.uid() = sender_id);

-- Grant permissions
GRANT ALL ON chat_messages TO authenticated;
GRANT ALL ON chat_messages TO anon;
