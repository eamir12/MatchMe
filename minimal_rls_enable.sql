-- Minimal RLS enablement
-- Just enable RLS and keep existing safe policies

-- Enable RLS on both tables
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- Verify that only safe policies remain
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename IN ('event_attendees', 'events')
ORDER BY tablename, policyname;

-- Check RLS is enabled
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename IN ('event_attendees', 'events');

-- If you still get errors, you can check which specific policies might be problematic:
-- The main culprit was: "Users can view event attendees for their events"
-- Make sure this policy was dropped in the previous step