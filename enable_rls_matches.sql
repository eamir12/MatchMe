-- Enable RLS on matches table and add policies for real-time updates
ALTER TABLE matches ENABLE ROW LEVEL SECURITY;

-- Drop any existing policies
DROP POLICY IF EXISTS "Users can view their own matches" ON matches;
DROP POLICY IF EXISTS "Users can manage their own matches" ON matches;

-- Policy for users to view matches where they are involved
CREATE POLICY "Users can view their own matches" ON matches
FOR SELECT TO authenticated USING (user1_id = auth.uid() OR user2_id = auth.uid());

-- Policy for users to insert matches (for match engine)
CREATE POLICY "Match engine can create matches" ON matches
FOR INSERT TO authenticated WITH CHECK (true);

-- Policy for users to delete their own matches
CREATE POLICY "Users can delete their own matches" ON matches
FOR DELETE TO authenticated USING (user1_id = auth.uid() OR user2_id = auth.uid());

-- Policy for users to update their own matches (if needed)
CREATE POLICY "Users can update their own matches" ON matches
FOR UPDATE TO authenticated USING (user1_id = auth.uid() OR user2_id = auth.uid()) WITH CHECK (user1_id = auth.uid() OR user2_id = auth.uid());