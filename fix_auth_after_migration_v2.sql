-- DIAGNOSTIC: Find all triggers/functions that might reference dropped columns
-- Run this to identify the exact issue

-- 1. List ALL triggers on auth tables
SELECT tgname AS trigger_name,
       tgrelid::regclass AS table_name,
       pg_get_triggerdef(oid) AS trigger_def
FROM pg_catalog.pg_trigger
WHERE tgrelid::regclass::text LIKE 'auth.%'
   OR tgrelid::regclass::text LIKE 'public.%';

-- 2. Check if there's a handle_new_user() function and its source
SELECT proname, prosrc
FROM pg_catalog.pg_proc
WHERE proname IN ('handle_new_user', 'grant_user', 'create_user');

-- 3. Check grants for supabase_auth_admin on public.users
SELECT grantee, privilege_type, table_schema, table_name
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'users'
  AND grantee = 'supabase_auth_admin';

-- 4. Check RLS policies on public.users
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_catalog.pg_policies
WHERE tablename = 'users' AND schemaname = 'public';

-- 5. Check if user_profiles has a valid row for the auth user
-- (Replace with actual user UUID from error logs)
-- SELECT * FROM user_profiles WHERE user_id = 'replace-with-user-uuid';
