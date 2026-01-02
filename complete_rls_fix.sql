-- Complete fix for infinite recursion in event_attendees and events RLS policies
-- This script will completely disable RLS on both tables to eliminate circular dependencies

-- First, drop ALL existing policies on event_attendees table
DROP POLICY IF EXISTS "event_attendees_select" ON event_attendees;
DROP POLICY IF EXISTS "users_select_event_attendees" ON event_attendees;
DROP POLICY IF EXISTS "event_attendees_policy" ON event_attendees;
DROP POLICY IF EXISTS "authenticated_users_see_attendees" ON event_attendees;
DROP POLICY IF EXISTS "users_own_attendance" ON event_attendees;

-- Drop ALL existing policies on events table (if any exist)
DROP POLICY IF EXISTS "events_select_policy" ON events;
DROP POLICY IF EXISTS "events_readable_by_attendees" ON events;
DROP POLICY IF EXISTS "users_can_read_events" ON events;
DROP POLICY IF EXISTS "authenticated_users_read_events" ON events;

-- Completely disable RLS on both tables
ALTER TABLE event_attendees DISABLE ROW LEVEL SECURITY;
ALTER TABLE events DISABLE ROW LEVEL SECURITY;

-- Verify the changes
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename IN ('event_attendees', 'events');

-- Also check that no policies remain
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename IN ('event_attendees', 'events');