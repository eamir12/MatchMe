-- ============================================================================
-- This script fetches all existing tables and admin functions in the database
-- Run this in Supabase SQL Editor to get the exact names
-- ============================================================================

-- List all tables in public schema
SELECT 'TABLES:' as type, table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;

-- List all functions starting with 'admin_'
SELECT 'FUNCTIONS:' as type, proname, pg_get_function_identity_arguments(oid) as args
FROM pg_proc 
WHERE pronamespace = 'public'::regnamespace
  AND proname LIKE 'admin_%'
ORDER BY proname;

-- List all functions starting with 'is_'
SELECT 'FUNCTIONS:' as type, proname, pg_get_function_identity_arguments(oid) as args
FROM pg_proc 
WHERE pronamespace = 'public'::regnamespace
  AND proname LIKE 'is_%'
ORDER BY proname;

-- List other common admin functions
SELECT 'FUNCTIONS:' as type, proname, pg_get_function_identity_arguments(oid) as args
FROM pg_proc 
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('count_target_users', 'get_broadcast_stats')
ORDER BY proname;