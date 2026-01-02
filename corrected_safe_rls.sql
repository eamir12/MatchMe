-- Corrected safe RLS re-enablement
-- This handles existing policies properly

-- First, re-enable RLS on both tables
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- Drop any conflicting policies first
DROP POLICY IF EXISTS "Users can manage own attendance" ON event_attendees;
DROP POLICY IF EXISTS "Authenticated users can view attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users own attendance only" ON event_attendees;

-- Keep existing safe policies on events table
-- "Anyone can view events" and "Authenticated users can create events" are already safe

-- Create new safe policies for event_attendees
-- Users can only manage their own attendance records
CREATE POLICY "Users manage own attendance" ON event_attendees
FOR ALL USING (user_id = auth.uid());

-- If you want to allow viewing all attendance (less secure but functional):
-- CREATE POLICY "Users can view all attendance" ON event_attendees
-- FOR SELECT TO authenticated USING (true);

-- Verify the current policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename IN ('event_attendees', 'events')
ORDER BY tablename, policyname;

-- Check RLS status
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename IN ('event_attendees', 'events');