-- Supabase Performance Advisor Fixes
-- Comprehensive fix for all performance warnings
-- Run this script in your Supabase SQL editor

-- ==========================================
-- IMPORTANT: BACKUP YOUR DATABASE BEFORE RUNNING THIS SCRIPT
-- ==========================================

-- ==========================================
-- FIX 1: auth_rls_initplan - Wrap auth functions in subqueries
-- ==========================================

-- Fix user_locations policies
DROP POLICY IF EXISTS "Users can manage own location" ON user_locations;
DROP POLICY IF EXISTS "Service role full access" ON user_locations;

CREATE POLICY "Users can manage own location" ON user_locations
FOR ALL USING (user_id = (select auth.uid()));

CREATE POLICY "Service role full access" ON user_locations
FOR ALL TO service_role USING (true);

-- Fix event_attendees policies
DROP POLICY IF EXISTS "Users own attendance only" ON event_attendees;

CREATE POLICY "Users own attendance only" ON event_attendees
FOR ALL USING (user_id = (select auth.uid()));

-- Fix matches policies
DROP POLICY IF EXISTS "Enable delete for service role" ON matches;
DROP POLICY IF EXISTS "Users can view their own matches" ON matches;
DROP POLICY IF EXISTS "Users can delete their own matches" ON matches;
DROP POLICY IF EXISTS "Users can update their own matches" ON matches;

DROP POLICY IF EXISTS "Users can view their matches" ON matches;
CREATE POLICY "Users can view their own matches" ON matches
FOR SELECT USING (user1_id = (select auth.uid()) OR user2_id = (select auth.uid()));

CREATE POLICY "Users can update their own matches" ON matches
FOR UPDATE USING (user1_id = (select auth.uid()) OR user2_id = (select auth.uid()));

CREATE POLICY "Users can delete their own matches" ON matches
FOR DELETE USING (user1_id = (select auth.uid()) OR user2_id = (select auth.uid()));

-- Note: Enable delete for service role should be for service_role only
DROP POLICY IF EXISTS "Enable delete for service role" ON matches;
CREATE POLICY "Enable delete for service role" ON matches
FOR DELETE TO service_role USING (true);

-- Fix users policies
DROP POLICY IF EXISTS "Users can update own profile" ON users;
DROP POLICY IF EXISTS "Users can insert own profile" ON users;

CREATE POLICY "Users can insert own profile" ON users
FOR INSERT WITH CHECK (id = (select auth.uid()));

CREATE POLICY "Users can update own profile" ON users
FOR UPDATE USING (id = (select auth.uid()));

-- ==========================================
-- FIX 2: Consolidate multiple permissive policies
-- ==========================================

-- Consolidate event_attendees policies for authenticated role
DROP POLICY IF EXISTS "Users can delete their own event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can update their own event attendance" ON event_attendees;
DROP POLICY IF EXISTS "Users can view their own attendance" ON event_attendees;
-- Keep "Users own attendance only" which covers all operations

-- Fix user_intents policies - change service policies to authenticated role
DROP POLICY IF EXISTS "user_intents_service" ON user_intents;
CREATE POLICY "user_intents_service" ON user_intents
FOR ALL TO authenticated USING ((select auth.uid()) IS NOT NULL);

-- Fix user_interests policies - change service policies to authenticated role
DROP POLICY IF EXISTS "user_interests_service" ON user_interests;
CREATE POLICY "user_interests_service" ON user_interests
FOR ALL TO authenticated USING ((select auth.uid()) IS NOT NULL);

-- Consolidate user_locations policies
-- Already consolidated above

-- Consolidate users policies for authenticated SELECT
DROP POLICY IF EXISTS "Users can view their own profile" ON users;
-- Keep "Users can view other users profiles" for broader access

-- Consolidate users policies for authenticated UPDATE
DROP POLICY IF EXISTS "Users can update their own profile" ON users;
-- Keep "Users can update own profile"

-- ==========================================
-- FIX 3: Drop duplicate indexes (CAUTION)
-- ==========================================

-- Check for duplicate constraints/indexes first
DO $$
DECLARE
    constraint_record RECORD;
BEGIN
    -- Check translations table for duplicate unique constraints
    FOR constraint_record IN
        SELECT conname, contype
        FROM pg_constraint
        WHERE conname LIKE '%translations_locale_key%'
        AND contype = 'u'
    LOOP
        RAISE NOTICE 'Found constraint: % (type: %)', constraint_record.conname, constraint_record.contype;
    END LOOP;

    -- Check user_profiles for duplicate indexes
    FOR constraint_record IN
        SELECT conname, contype
        FROM pg_constraint
        WHERE conname LIKE '%user_profiles%'
        AND contype IN ('u', 'p')
    LOOP
        RAISE NOTICE 'Found user_profiles constraint: % (type: %)', constraint_record.conname, constraint_record.contype;
    END LOOP;
END $$;

-- Safe duplicate drops based on index analysis
-- Drop duplicate unique constraint on translations (keep translations_locale_key_uq)
ALTER TABLE translations DROP CONSTRAINT IF EXISTS translations_locale_key_key;

-- DO NOT DROP user_profiles_pkey (it's the primary key)
-- The user_profiles_user_id_intent_type_key might be intentionally separate
-- Only uncomment if you're certain it's a true duplicate:
-- ALTER TABLE user_profiles DROP INDEX IF EXISTS user_profiles_user_id_intent_type_key;

-- Check for other potential duplicates (intents and interests tables)
-- These appear to have both _idx and _key versions - check if they're identical
-- SELECT indexdef FROM pg_indexes WHERE tablename = 'intents' AND indexname LIKE '%key%';

-- ==========================================
-- VERIFICATION
-- ==========================================

-- Check policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- Check indexes
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;