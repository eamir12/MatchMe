-- Secure RLS policies alternative
-- This provides better security while avoiding recursion

-- Enable RLS on both tables
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- Drop any existing policies first to start clean
DROP POLICY IF EXISTS "Users can manage own attendance" ON event_attendees;
DROP POLICY IF EXISTS "Authenticated users can view attendance" ON event_attendees;
DROP POLICY IF EXISTS "Anyone can view events" ON events;
DROP POLICY IF EXISTS "Authenticated users can create events" ON events;

-- More secure policies for event_attendees
-- Users can only see/modify their own attendance records
CREATE POLICY "Users own attendance only" ON event_attendees
FOR ALL USING (user_id = auth.uid());

-- For viewing other attendees, use a different approach:
-- Create a view or use application-level filtering instead of RLS policies
-- This avoids the self-referencing subquery issue

-- Secure policies for events
-- Allow authenticated users to view events
CREATE POLICY "Authenticated users can view events" ON events
FOR SELECT TO authenticated USING (auth.role() = 'authenticated');

-- Allow authenticated users to create events
CREATE POLICY "Authenticated users can create events" ON events
FOR INSERT TO authenticated WITH CHECK (auth.role() = 'authenticated');

-- Verify the policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename IN ('event_attendees', 'events')
ORDER BY tablename, policyname;