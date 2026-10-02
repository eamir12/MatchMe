# RLS Security Guide: Safe Re-enablement

You're absolutely right to be concerned about security. RLS (Row Level Security) is crucial for protecting user data. Here's how to safely re-enable it.

## Security Analysis

### Current Risk Without RLS
Without RLS, any authenticated user could potentially:
- View all event attendance records across all events
- See who attended events they weren't invited to
- Access sensitive event information

### Safe RLS Re-enablement Options

## Option 1: Basic Security (Recommended to start)

Run this in your Supabase SQL Editor:

```sql
-- Safe RLS re-enablement with basic security
-- Re-enable RLS on both tables
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- Create safe policies for event_attendees
CREATE POLICY "Users can manage own attendance" ON event_attendees
FOR ALL USING (user_id = auth.uid());

CREATE POLICY "Authenticated users can view attendance" ON event_attendees
FOR SELECT TO authenticated USING (true);

-- Safe policies for events
CREATE POLICY "Anyone can view events" ON events
FOR SELECT USING (true);

CREATE POLICY "Authenticated users can create events" ON events
FOR INSERT TO authenticated WITH CHECK (true);
```

**Security Level**: Basic - Users can see all attendance records but can only modify their own.

## Option 2: Enhanced Security (Better protection)

Run this instead:

```sql
-- Enhanced security with better access control
ALTER TABLE event_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- More restrictive policies
CREATE POLICY "Users own attendance only" ON event_attendees
FOR ALL USING (user_id = auth.uid());

CREATE POLICY "Authenticated users can view events" ON events
FOR SELECT TO authenticated USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can create events" ON events
FOR INSERT TO authenticated WITH CHECK (auth.role() = 'authenticated');
```

**Security Level**: Enhanced - Users can only see their own attendance records.

## What We Fixed

The original problem was this policy:
```sql
"Users can view event attendees for their events" - 
EXISTS (SELECT 1 FROM event_attendees ea WHERE ea.event_id = event_attendees.event_id AND ea.user_id = auth.uid())
```

This created a **circular dependency** because:
1. Query joins `event_attendees` with `events`
2. RLS policy on `event_attendees` checks `event_attendees` again
3. This creates infinite recursion

## Testing Your Choice

After enabling RLS with either option:

1. **Test your app** - Make sure the infinite recursion error is gone
2. **Verify security** - Check that users can only access appropriate data
3. **Monitor performance** - Ensure queries are still fast

## Files Available

- `safe_rls_re_enable.sql` - Basic security approach
- `secure_rls_policies.sql` - Enhanced security approach

## Recommendation

Start with **Option 1 (Basic Security)** to ensure your app works without errors, then gradually move to **Option 2 (Enhanced Security)** if you need tighter access control.

The key is that both options avoid the self-referencing subquery that caused the infinite recursion.