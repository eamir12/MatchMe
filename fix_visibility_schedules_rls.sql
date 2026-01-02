-- Fix RLS policy for user_visibility_schedules to allow service role access
-- This is needed for the cron job to manage visibility schedules

-- Drop existing restrictive policies
DROP POLICY IF EXISTS "Users can view their own visibility schedules" ON user_visibility_schedules;
DROP POLICY IF EXISTS "Users can update their own visibility schedules" ON user_visibility_schedules;

-- Create new policies that allow both user access and service role access
CREATE POLICY "Users can view their own visibility schedules" ON user_visibility_schedules
FOR SELECT USING (user_id = auth.uid() OR auth.role() = 'service_role');

CREATE POLICY "Users can update their own visibility schedules" ON user_visibility_schedules
FOR UPDATE USING (user_id = auth.uid() OR auth.role() = 'service_role');

CREATE POLICY "Service role can manage visibility schedules" ON user_visibility_schedules
FOR ALL USING (auth.role() = 'service_role');

-- Also ensure the service role has proper grants
GRANT SELECT, INSERT, UPDATE, DELETE ON user_visibility_schedules TO service_role;

-- Fix RLS policy for users table to allow service role to update system_visibility_status
-- This is needed for the cron job visibility scheduling functionality

-- Drop existing restrictive policy for users updates
DROP POLICY IF EXISTS "Users can update their own profile" ON users;

-- Create new policy that allows both user access and service role access for system fields
CREATE POLICY "Users can update their own profile" ON users
FOR UPDATE USING (id = auth.uid() OR auth.role() = 'service_role');

-- Ensure service role has proper grants on users table
GRANT SELECT, UPDATE ON users TO service_role;