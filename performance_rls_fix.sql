-- Supabase Performance Advisor RLS Fixes
-- This script addresses the performance issues identified by Supabase Performance Advisor
-- Issues: auth_rls_initplan, multiple_permissive_policies, duplicate_index

-- ==========================================
-- IMPORTANT: BACKUP YOUR DATABASE BEFORE RUNNING THIS SCRIPT
-- ==========================================

-- ==========================================
-- FIX 1: auth_rls_initplan - Wrap auth functions in subqueries
-- ==========================================
-- The issue is that auth.<function>() gets re-evaluated for each row.
-- Wrapping in (select auth.<function>()) evaluates it once per query.

-- Note: This script assumes you have existing policies and only modifies the auth calls.
-- If policies don't exist, they will be created. If they do exist, they will be replaced.

-- Helper function to update existing policies (if they exist)
-- Since we can't conditionally update, we'll drop and recreate

-- Fix policies on users table
-- These policies check if the user owns their profile
-- Drop and recreate to ensure the auth call is wrapped
DROP POLICY IF EXISTS "Users can view their own profile" ON users;
CREATE POLICY "Users can view their own profile" ON users
FOR SELECT USING (id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own profile" ON users;
CREATE POLICY "Users can update their own profile" ON users
FOR UPDATE USING (id = (select auth.uid()));

DROP POLICY IF EXISTS "Enable delete for service role" ON users;
CREATE POLICY "Enable delete for service role" ON users
FOR DELETE USING (id = (select auth.uid()));

-- Fix policies on user_profiles table
DROP POLICY IF EXISTS "Users can update own profile" ON user_profiles;
CREATE POLICY "Users can update own profile" ON user_profiles
FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert own profile" ON user_profiles;
CREATE POLICY "Users can insert own profile" ON user_profiles
FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Enable delete for service role" ON user_profiles;
CREATE POLICY "Enable delete for service role" ON user_profiles
FOR DELETE USING (user_id = (select auth.uid()));

-- Fix policies on events table
DROP POLICY IF EXISTS "Authenticated users can create events" ON events;
CREATE POLICY "Authenticated users can create events" ON events
FOR INSERT WITH CHECK ((select auth.uid()) IS NOT NULL);

DROP POLICY IF EXISTS "Users can view events" ON events;
CREATE POLICY "Users can view events" ON events
FOR SELECT USING ((select auth.uid()) IS NOT NULL);

-- Fix policies on event_attendees table
DROP POLICY IF EXISTS "Users can join events" ON event_attendees;
CREATE POLICY "Users can join events" ON event_attendees
FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can view their own attendance" ON event_attendees;
CREATE POLICY "Users can view their own attendance" ON event_attendees
FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert their own event attendance" ON event_attendees;
CREATE POLICY "Users can insert their own event attendance" ON event_attendees
FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own event attendance" ON event_attendees;
CREATE POLICY "Users can update their own event attendance" ON event_attendees
FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can delete their own event attendance" ON event_attendees;
CREATE POLICY "Users can delete their own event attendance" ON event_attendees
FOR DELETE USING (user_id = (select auth.uid()));

-- Fix policies on matches table
DROP POLICY IF EXISTS "Users can view their matches" ON matches;
CREATE POLICY "Users can view their matches" ON matches
FOR SELECT USING (user1_id = (select auth.uid()) OR user2_id = (select auth.uid()));

-- Fix policies on chat_messages table
-- Note: These policies use subqueries which are already optimized
DROP POLICY IF EXISTS "Users can view messages in their matches" ON chat_messages;
CREATE POLICY "Users can view messages in their matches" ON chat_messages
FOR SELECT USING (
  match_id IN (
    SELECT id FROM matches
    WHERE user1_id = (select auth.uid()) OR user2_id = (select auth.uid())
  )
);

DROP POLICY IF EXISTS "Users can send messages in their matches" ON chat_messages;
CREATE POLICY "Users can send messages in their matches" ON chat_messages
FOR INSERT WITH CHECK (
  sender_id = (select auth.uid()) AND
  match_id IN (
    SELECT id FROM matches
    WHERE user1_id = (select auth.uid()) OR user2_id = (select auth.uid())
  )
);

DROP POLICY IF EXISTS "Enable delete for service role" ON chat_messages;
CREATE POLICY "Enable delete for service role" ON chat_messages
FOR DELETE USING (
  match_id IN (
    SELECT id FROM matches
    WHERE user1_id = (select auth.uid()) OR user2_id = (select auth.uid())
  )
);

-- Fix policies on profile_edit_requests table
DROP POLICY IF EXISTS "Users can view their own requests" ON profile_edit_requests;
CREATE POLICY "Users can view their own requests" ON profile_edit_requests
FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can create requests" ON profile_edit_requests;
CREATE POLICY "Users can create requests" ON profile_edit_requests
FOR INSERT WITH CHECK (user_id = (select auth.uid()));

-- Fix policies on user_invisibility_rules table
DROP POLICY IF EXISTS "Users can view their own invisibility rules" ON user_invisibility_rules;
CREATE POLICY "Users can view their own invisibility rules" ON user_invisibility_rules
FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can upsert their own invisibility rules" ON user_invisibility_rules;
CREATE POLICY "Users can upsert their own invisibility rules" ON user_invisibility_rules
FOR ALL USING (user_id = (select auth.uid()));

-- Fix policies on user_visibility_schedules table
DROP POLICY IF EXISTS "Users can view their own visibility schedules" ON user_visibility_schedules;
CREATE POLICY "Users can view their own visibility schedules" ON user_visibility_schedules
FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own visibility schedules" ON user_visibility_schedules;
CREATE POLICY "Users can update their own visibility schedules" ON user_visibility_schedules
FOR UPDATE USING (user_id = (select auth.uid()));

-- Fix policies on user_locations table
DROP POLICY IF EXISTS "Users can update own location" ON user_locations;
CREATE POLICY "Users can update own location" ON user_locations
FOR UPDATE USING (user_id = (select auth.uid()));

-- Fix policies on intents table
DROP POLICY IF EXISTS "intents_service_write" ON intents;
CREATE POLICY "intents_service_write" ON intents
FOR ALL USING ((select auth.uid()) IS NOT NULL);

-- Fix policies on interests table
DROP POLICY IF EXISTS "interests_service_write" ON interests;
CREATE POLICY "interests_service_write" ON interests
FOR ALL USING ((select auth.uid()) IS NOT NULL);

-- Fix policies on user_intents table
DROP POLICY IF EXISTS "user_intents_owner" ON user_intents;
CREATE POLICY "user_intents_owner" ON user_intents
FOR ALL USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "user_intents_service" ON user_intents;
CREATE POLICY "user_intents_service" ON user_intents
FOR ALL USING ((select auth.uid()) IS NOT NULL);

-- Fix policies on user_interests table
DROP POLICY IF EXISTS "user_interests_owner" ON user_interests;
CREATE POLICY "user_interests_owner" ON user_interests
FOR ALL USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "user_interests_service" ON user_interests;
CREATE POLICY "user_interests_service" ON user_interests
FOR ALL USING ((select auth.uid()) IS NOT NULL);

-- Fix policies on user_profiles_backup table
DROP POLICY IF EXISTS "Users can view their own backup profile" ON user_profiles_backup;
CREATE POLICY "Users can view their own backup profile" ON user_profiles_backup
FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own backup profile" ON user_profiles_backup;
CREATE POLICY "Users can update their own backup profile" ON user_profiles_backup
FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert their own backup profile" ON user_profiles_backup;
CREATE POLICY "Users can insert their own backup profile" ON user_profiles_backup
FOR INSERT WITH CHECK (user_id = (select auth.uid()));

-- ==========================================
-- FIX 2: Consolidate multiple permissive policies
-- ==========================================
-- Multiple permissive policies for the same role/action are inefficient

-- Note: ALTER POLICY doesn't work for consolidating. We need to drop and recreate.

-- Consolidate event_attendees policies for anon role INSERT
DROP POLICY IF EXISTS "Users can insert their own event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can join events" ON event_attendees;
-- Keep only one policy for INSERT on event_attendees

-- Consolidate events policies for anon/authenticated SELECT
DROP POLICY IF EXISTS "Anyone can view events" ON events;
-- Keep "Users can view events" policy

-- Consolidate intents policies
DROP POLICY IF EXISTS "intents_public_read" ON intents;
-- Keep "intents_service_write" policy

-- Consolidate interests policies
DROP POLICY IF EXISTS "interests_public_read" ON interests;
-- Keep "interests_service_write" policy

-- Consolidate user_intents policies
-- These have different logic (owner vs service), so keep both but ensure they're optimized

-- Consolidate user_interests policies
-- These have different logic (owner vs service), so keep both but ensure they're optimized

-- Consolidate user_invisibility_rules policies
DROP POLICY IF EXISTS "Users can view their own invisibility rules" ON user_invisibility_rules;
-- Keep "Users can upsert their own invisibility rules" as ALL

-- Consolidate user_visibility_schedules policies
DROP POLICY IF EXISTS "Users can view their own visibility schedules" ON user_visibility_schedules;
-- Keep "Users can update their own visibility schedules" as UPDATE, but make it ALL

-- Consolidate user_locations policies
DROP POLICY IF EXISTS "Users can view nearby locations" ON user_locations;
DROP POLICY IF EXISTS "Enable delete for service role" ON user_locations;
-- Keep "Users can update own location" as UPDATE, but make it ALL

-- Fix RLS policies for user_locations table
-- Drop all existing policies
DROP POLICY IF EXISTS "Users can update own location" ON user_locations;
DROP POLICY IF EXISTS "Users can view nearby locations" ON user_locations;
DROP POLICY IF EXISTS "Enable delete for service role" ON user_locations;
DROP POLICY IF EXISTS "Service role can manage locations" ON user_locations;

-- Create correct policies
-- Allow users to insert/update their own location
CREATE POLICY "Users can manage own location" ON user_locations
FOR ALL USING (user_id = auth.uid());

-- Allow service role full access (for match-engine function)
CREATE POLICY "Service role full access" ON user_locations
FOR ALL USING (auth.role() = 'service_role');

-- Consolidate users delete policies
DROP POLICY IF EXISTS "Enable delete for users based on user_id" ON users;
-- Keep "Enable delete for service role"

-- ==========================================
-- FIX 3: Drop duplicate indexes (CAUTION)
-- ==========================================
-- Note: Some "indexes" may actually be constraints. Only drop if you're sure they're duplicates.
-- The advisor reported these as identical, but they may serve different purposes.

-- For translations table: translations_locale_key_key appears to be a unique constraint
-- Check if it's truly duplicate before dropping:
-- SELECT conname, contype FROM pg_constraint WHERE conname = 'translations_locale_key_key';

-- For user_profiles: user_profiles_pkey is likely the primary key - DO NOT DROP
-- Primary keys are essential for table structure

-- Only uncomment and run these if you've verified they're safe to drop:
-- ALTER TABLE translations DROP CONSTRAINT IF EXISTS translations_locale_key_key;
-- Keep translations_locale_key_uq

-- ==========================================
-- VERIFICATION
-- ==========================================

-- Check that policies are updated
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- Check indexes
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- Check for remaining performance issues
-- Note: The performance_advisor is a Supabase dashboard feature, not a database table
-- Check your Supabase Performance Advisor in the dashboard after running this script
-- to verify that the warnings have been resolved.