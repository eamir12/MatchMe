-- Add missing UPDATE policy for chat_messages to allow translation updates
-- This policy allows users to update messages in their matches (for translations)

CREATE POLICY "Users can update messages in their matches" ON chat_messages
FOR UPDATE USING (
  match_id IN (
    SELECT id FROM matches
    WHERE user1_id = (select auth.uid()) OR user2_id = (select auth.uid())
  )
)
WITH CHECK (
  match_id IN (
    SELECT id FROM matches
    WHERE user1_id = (select auth.uid()) OR user2_id = (select auth.uid())
  )
);