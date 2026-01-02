# Final RLS Re-enablement Instructions

Since you got a "policy already exists" error, here's the corrected step-by-step approach:

## Step 1: Simple RLS Re-enablement (Try this first)

Run this minimal script in your Supabase SQL Editor:

```sql
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
```

## Step 2: If Step 1 works, test your app

- Check if the infinite recursion error is gone
- Verify your event attendance queries work properly
- Make sure users can still access the data they need

## Step 3: If you need to modify policies

If Step 1 works but you want different policies, run this corrected version:

```sql
-- Corrected safe RLS policies
-- Enable RLS
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- Drop any conflicting policies first
DROP POLICY IF EXISTS "Users can manage own attendance" ON event_attendees;
DROP POLICY IF EXISTS "Authenticated users can view attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users own attendance only" ON event_attendees;

-- Create new safe policy
CREATE POLICY "Users manage own attendance" ON event_attendees
FOR ALL USING (user_id = auth.uid());
```

## Key Points

1. **The main fix was removing** `"Users can view event attendees for their events"` - the policy with the self-referencing subquery
2. **Keep it simple** - Start with minimal policies and add complexity only if needed
3. **Test thoroughly** - Make sure your app works after each change

## Files Available

- `minimal_rls_enable.sql` - Simplest approach (start here)
- `corrected_safe_rls.sql` - If you need to modify policies
- `corrected_safe_rls.sql` - Alternative policy approach

The infinite recursion should be resolved as long as you don't recreate policies that reference the same table in subqueries.