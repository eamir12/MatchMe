-- Check current permissions on user_activity table
SELECT
    table_name,
    privilege_type,
    grantee
FROM information_schema.table_privileges
WHERE table_schema = 'public'
    AND table_name = 'user_activity'
ORDER BY privilege_type, grantee;

-- Check if RLS is enabled on user_activity
SELECT
    tablename,
    rowsecurity
FROM pg_tables
WHERE schemaname = 'public'
    AND tablename = 'user_activity';