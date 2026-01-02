-- Enable RLS on users table if not already
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Allow authenticated users to read basic profile info of other users
-- This is needed for matching functionality
CREATE POLICY "Users can view other users profiles" ON users
FOR SELECT TO authenticated USING (true);

-- Users can update their own profile
CREATE POLICY "Users can update own profile" ON users
FOR UPDATE TO authenticated USING (id = auth.uid());

-- Users can insert their own profile (during signup)
CREATE POLICY "Users can insert own profile" ON users
FOR INSERT TO authenticated WITH CHECK (id = auth.uid());