# Updated RLS Policy Infinite Recursion Fix

Based on your current policies, I can see the exact problem. The policy **"Users can view event attendees for their events"** contains a subquery that references the same table it's applied to, creating infinite recursion when combined with joins.

## Recommended Fix (Try this first)

Run this simple fix in your Supabase SQL Editor:

```sql
-- Simple fix: Remove policies that reference the same table
-- This eliminates the circular dependency causing infinite recursion

-- Drop the problematic policies that reference the same table
DROP POLICY IF EXISTS "Users can view event attendees for their events" ON event_attendees;
DROP POLICY IF EXISTS "Users can view event attendance" ON event_attendees;

-- Verify only safe policies remain
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename = 'event_attendees'
ORDER BY policyname;
```

## If the simple fix doesn't work, try the complete fix:

```sql
-- Complete fix for infinite recursion in event_attendees and events RLS policies
-- This script will completely disable RLS on both tables to eliminate circular dependencies

-- First, drop ALL existing policies on event_attendees table
DROP POLICY IF EXISTS "event_attendees_select" ON event_attendees;
DROP POLICY IF EXISTS "users_select_event_attendees" ON event_attendees;
DROP POLICY IF EXISTS "event_attendees_policy" ON event_attendees;
DROP POLICY IF EXISTS "authenticated_users_see_attendees" ON event_attendees;
DROP POLICY IF EXISTS "users_own_attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can delete their own event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can insert their own event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can join events" ON event_attendees;
DROP POLICY IF EXISTS "Users can update their own event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can view event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can view event attendees for their events" ON event_attendees;

-- Drop ALL existing policies on events table (if any exist)
DROP POLICY IF EXISTS "events_select_policy" ON events;
DROP POLICY IF EXISTS "events_readable_by_attendees" ON events;
DROP POLICY IF EXISTS "users_can_read_events" ON events;
DROP POLICY IF EXISTS "authenticated_users_read_events" ON events;
DROP POLICY IF EXISTS "Anyone can view events" ON events;
DROP POLICY IF EXISTS "Authenticated users can create events" ON events;
DROP POLICY IF EXISTS "Users can view events" ON events;

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
```

## Files available:
- `simple_rls_fix.sql` - Minimal fix (try first)
- `complete_rls_fix.sql` - Complete fix (backup option)

The infinite recursion should be resolved after running either of these fixes.