-- Supabase Performance Advisor Index Fixes
-- This script addresses the performance issues identified by Supabase Performance Advisor
-- Issues: unindexed_foreign_keys, no_primary_key, unused_index

-- ==========================================
-- IMPORTANT: BACKUP YOUR DATABASE BEFORE RUNNING THIS SCRIPT
-- ==========================================

-- ==========================================
-- FIX 1: Create indexes for unindexed foreign keys
-- ==========================================

-- Create index for intents.parent_id (foreign key to intents.id)
CREATE INDEX IF NOT EXISTS idx_intents_parent_id ON public.intents (parent_id);

-- Create index for interests.parent_id (foreign key to interests.id)
CREATE INDEX IF NOT EXISTS idx_interests_parent_id ON public.interests (parent_id);

-- Create index for user_intents.intent_id (foreign key to intents.id)
CREATE INDEX IF NOT EXISTS idx_user_intents_intent_id ON public.user_intents (intent_id);

-- Create index for user_interests.interest_id (foreign key to interests.id)
CREATE INDEX IF NOT EXISTS idx_user_interests_interest_id ON public.user_interests (interest_id);

-- ==========================================
-- FIX 2: Add primary key to user_profiles_backup
-- ==========================================
-- Assuming the table has an 'id' column or 'user_id' as primary key
-- If it has 'id', use that; otherwise, use 'user_id'
-- Check the table structure first and adjust accordingly

-- Option 1: If there's an 'id' column (most common)
-- ALTER TABLE public.user_profiles_backup ADD PRIMARY KEY (id);

-- Option 2: If using 'user_id' as primary key (if 'id' doesn't exist)
ALTER TABLE public.user_profiles_backup ADD PRIMARY KEY (user_id);

-- ==========================================
-- FIX 3: Drop unused indexes
-- ==========================================
-- CAUTION: Only drop if confirmed unused. These were reported as unused.

-- Drop unused index on matches.event_id
DROP INDEX IF EXISTS public.idx_matches_event_id;

-- Drop unused index on chat_messages.match_id
DROP INDEX IF EXISTS public.idx_chat_messages_match_id;

-- Drop unused index on chat_messages.created_at
DROP INDEX IF EXISTS public.idx_chat_messages_created_at;

-- Drop unused index on profile_edit_requests.status
DROP INDEX IF EXISTS public.idx_profile_edit_requests_status;

-- Drop unused index on user_locations.updated_at
DROP INDEX IF EXISTS public.idx_user_locations_updated_at;

-- ==========================================
-- VERIFICATION
-- ==========================================

-- Check that indexes were created
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
AND tablename IN ('intents', 'interests', 'user_intents', 'user_interests', 'user_profiles_backup', 'matches', 'chat_messages', 'profile_edit_requests', 'user_locations')
ORDER BY tablename, indexname;

-- Check primary key on user_profiles_backup
SELECT conname, contype, conkey
FROM pg_constraint
WHERE conrelid = 'public.user_profiles_backup'::regclass
AND contype = 'p';

-- Check for remaining performance issues
-- Check your Supabase Performance Advisor in the dashboard after running this script
-- to verify that the warnings have been resolved.