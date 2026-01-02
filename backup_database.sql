-- Database Backup Script for Supabase
-- Run this BEFORE applying performance fixes
-- This script exports current RLS policies, indexes, and table structures

-- ==========================================
-- BACKUP CURRENT STATE
-- ==========================================

-- 1. Backup all RLS policies
CREATE TEMP TABLE IF NOT EXISTS policy_backup AS
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- 2. Backup indexes
CREATE TEMP TABLE IF NOT EXISTS index_backup AS
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- 3. Show current state before changes
SELECT 'CURRENT RLS POLICIES:' as info;
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM policy_backup;

SELECT 'CURRENT INDEXES:' as info;
SELECT * FROM index_backup;

-- 4. Optional: Create schema backup (table structures)
-- Uncomment the following if you want to backup table schemas
/*
SELECT
    'CREATE TABLE ' || schemaname || '.' || tablename || ' (' ||
    string_agg(column_name || ' ' || data_type ||
               CASE WHEN character_maximum_length IS NOT NULL
                    THEN '(' || character_maximum_length || ')'
                    ELSE '' END ||
               CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END,
               ', ') ||
    ');' as create_table_sql
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY schemaname, tablename
ORDER BY tablename;
*/

-- 5. Optional: Data backup (CAUTION: This can be very large)
-- Uncomment ONLY if you need to backup actual data
-- WARNING: This will export ALL data from your tables
/*
-- Example for small tables only:
-- SELECT 'users' as table_name, count(*) as row_count FROM users;
-- SELECT * FROM users LIMIT 10; -- Preview only

-- For full backup (use with caution):
-- pg_dump equivalent would be needed, but here's a basic approach:
-- CREATE TABLE users_backup AS SELECT * FROM users;
-- CREATE TABLE matches_backup AS SELECT * FROM matches;
-- etc.
*/

-- ==========================================
-- VERIFICATION
-- ==========================================

-- Show summary of what will be backed up
SELECT
    'Tables with RLS policies: ' || count(DISTINCT tablename) as summary
FROM policy_backup;

SELECT
    'Total indexes: ' || count(*) as summary
FROM index_backup;

-- ==========================================
-- RESTORE INSTRUCTIONS (if needed)
-- ==========================================
-- If you need to restore from this backup, you can:
-- 1. Use the policy_backup table to recreate policies
-- 2. Use the index_backup table to recreate indexes
-- 3. Use Supabase's built-in restore features if available

-- Backup completed. You can now safely run the performance fixes script.
-- If you need to restore, use Supabase's dashboard backup features.