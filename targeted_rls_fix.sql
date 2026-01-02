-- Targeted fix for the specific infinite recursion policy
-- This addresses the "Users can view event attendees for their events" policy that's causing the issue

-- First, drop the most problematic policy that references the same table
DROP POLICY IF EXISTS "Users can view event attendees for their events" ON event_attendees;

-- Also drop other policies that might cause issues with joins
DROP POLICY IF EXISTS "Users can view event attendance" ON event_attendees;

-- Keep the essential policies but simplify the problematic ones
-- Create a simple policy that allows authenticated users to read their own attendance records
CREATE POLICY "Users can read own attendance" ON event_attendees
FOR SELECT TO authenticated 
USING (user_id = auth.uid());

-- Create a policy to allow users to see attendees of events they're attending (safer approach)
CREATE POLICY "Users can see attendees of their events" ON event_attendees
FOR SELECT TO authenticated 
USING (
  EXISTS (
    SELECT 1 FROM event_attendees ea 
    WHERE ea.event_id = event_attendees.event_id 
    AND ea.user_id = auth.uid()
  )
);

-- Verify the changes
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies 
WHERE tablename = 'event_attendees'
ORDER BY policyname;