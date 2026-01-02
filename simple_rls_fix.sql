-- Simple fix: Remove policies that reference the same table
-- This eliminates the circular dependency causing infinite recursion

-- Drop the problematic policies that reference the same table
DROP POLICY IF EXISTS "Users can view event attendees for their events" ON event_attendees;
DROP POLICY IF EXISTS "Users can view event attendance" ON event_attendees;

-- Keep only the basic CRUD policies that don't cause recursion
-- These policies are safe because they don't reference other tables or the same table in subqueries

-- Verify only safe policies remain
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename = 'event_attendees'
ORDER BY policyname;

-- If you still get errors, you can completely disable RLS with:
-- ALTER TABLE event_attendees DISABLE ROW LEVEL SECURITY;