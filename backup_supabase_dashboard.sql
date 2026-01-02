-- Alternative Supabase Backup Methods
-- These don't require installing pg_dump locally

-- ==========================================
-- METHOD 1: Supabase Dashboard Backup (Easiest)
-- ==========================================
-- 1. Go to: https://supabase.com/dashboard/project/YOUR_PROJECT/settings/database
-- 2. Scroll to "Backups" section
-- 3. Click "Create backup"
-- 4. Download the ZIP file
-- This gives you a complete backup without any local setup

-- ==========================================
-- METHOD 2: Supabase CLI (If installed)
-- ==========================================
-- Install: npm install -g supabase
-- Then run: supabase db dump --db-url "YOUR_CONNECTION_STRING" > backup.sql

-- ==========================================
-- METHOD 3: SQL-Based Data Export (No external tools needed)
-- ==========================================
-- Run these queries in Supabase SQL Editor to export your data

-- Export table schemas
SELECT
    'CREATE TABLE ' || table_name || ' (' ||
    string_agg(column_name || ' ' || data_type ||
               CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END,
               ', ') || ');' as create_statements
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY table_name
ORDER BY table_name;

-- Export RLS policies
SELECT
    'CREATE POLICY "' || policyname || '" ON ' || tablename ||
    ' FOR ' || cmd ||
    CASE WHEN roles IS NOT NULL THEN ' TO ' || array_to_string(roles, ',') ELSE '' END ||
    ' USING (' || qual || ');' as policy_sql
FROM pg_policies
WHERE schemaname = 'public';

-- Export indexes
SELECT
    'CREATE ' || indexdef || ';' as index_sql
FROM pg_indexes
WHERE schemaname = 'public' AND tablename NOT LIKE 'pg_%';

-- ==========================================
-- METHOD 4: Data-Only Backup (For Large Databases)
-- ==========================================
-- If your database is very large, backup schema separately from data

-- Schema backup (run this first)
SELECT
    schemaname, tablename, tableowner,
    'Table: ' || tablename as info
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;

-- Then backup individual tables (example for small tables)
-- SELECT * FROM users LIMIT 1000;  -- Preview
-- SELECT * FROM users;  -- Full export (be careful with large tables)

-- ==========================================
-- METHOD 5: Automated Backup with Functions
-- ==========================================
-- Create a function to export data as JSON (useful for APIs)

CREATE OR REPLACE FUNCTION export_table_as_json(table_name text)
RETURNS json AS $$
DECLARE
    result json;
BEGIN
    EXECUTE format('SELECT json_agg(t) FROM %I t', table_name) INTO result;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Usage example:
-- SELECT export_table_as_json('users');
-- This returns table data as JSON that you can save

-- ==========================================
-- METHOD 6: Third-Party Tools
-- ==========================================
-- Tools like TablePlus, DataGrip, or DBeaver can connect to Supabase
-- and export data directly through their GUI interfaces

-- ==========================================
-- QUICK SCHEMA BACKUP (Copy and save this output)
-- ==========================================

-- Current database info
SELECT
    current_database() as database_name,
    current_user as current_user,
    version() as postgres_version;

-- Table counts
SELECT
    schemaname,
    tablename,
    n_tup_ins as rows_inserted,
    n_tup_upd as rows_updated,
    n_tup_del as rows_deleted,
    n_live_tup as live_rows
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;