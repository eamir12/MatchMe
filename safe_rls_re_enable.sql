-- Safe RLS re-enablement script
-- This script re-enables RLS with only safe policies that won't cause recursion

-- First, re-enable RLS on both tables
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- Create safe policies for event_attendees table
-- These policies don't reference the same table in subqueries, avoiding recursion

-- Allow users to manage their own attendance records
CREATE POLICY "Users can manage own attendance" ON event_attendees
FOR ALL USING (user_id = auth.uid());

-- Allow users to view all attendance records (simpler approach, no self-reference)
CREATE POLICY "Authenticated users can view attendance" ON event_attendees
FOR SELECT TO authenticated USING (true);

-- Create safe policies for events table
-- These policies are already safe and don't cause recursion

-- Allow anyone to view events (this was already working)
CREATE POLICY "Anyone can view events" ON events
FOR SELECT USING (true);

-- Allow authenticated users to create events
CREATE POLICY "Authenticated users can create events" ON events
FOR INSERT TO authenticated WITH CHECK (true);

-- Verify the current policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename IN ('event_attendees', 'events')
ORDER BY tablename, policyname;

-- Check RLS status
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename IN ('event_attendees', 'events');