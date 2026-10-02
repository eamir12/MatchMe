-- Migration: Debug is_online error on logout
-- Date: 2026-05-06
-- Purpose: Investigate what's causing "column is_online of relation users does not exist" error

-- Check for any functions that reference is_online and users table together
SELECT
    p.proname as function_name,
    pg_get_functiondef(p.oid) as function_definition
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
AND p.prokind = 'f'
AND pg_get_functiondef(p.oid) LIKE '%is_online%'
AND pg_get_functiondef(p.oid) LIKE '%users%';

-- Check for any triggers on users table
SELECT
    t.tgname as trigger_name,
    p.proname as function_name,
    pg_get_functiondef(p.oid) as function_definition
FROM pg_trigger t
JOIN pg_class c ON t.tgrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
JOIN pg_proc p ON t.tgfoid = p.oid
WHERE n.nspname = 'public'
AND c.relname = 'users'
AND pg_get_functiondef(p.oid) LIKE '%is_online%';

-- Check current definition of set_user_offline
SELECT
    pg_get_functiondef(p.oid) as set_user_offline_definition
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
AND p.proname = 'set_user_offline';

-- Check if is_online column exists on users table (it shouldn't)
SELECT
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'public'
AND table_name = 'users'
AND column_name = 'is_online';

-- Check if is_online column exists on user_activity table (it should)
SELECT
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'public'
AND table_name = 'user_activity'
AND column_name = 'is_online';