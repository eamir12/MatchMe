-- Restore SELECT permission on chats for authenticated users
-- The RLS policies ensure users can only view their own chats
-- This fixes permission errors when accessing chats table

-- Grant SELECT back to authenticated users
GRANT SELECT ON TABLE public.chats TO authenticated;

-- Grant SELECT to anon as well (for unauthenticated access if needed)
GRANT SELECT ON TABLE public.chats TO anon;

-- Ensure all other permissions are still granted
GRANT INSERT, UPDATE, DELETE ON TABLE public.chats TO authenticated;

-- Verify the permissions
SELECT
    table_name,
    privilege_type,
    grantee
FROM information_schema.table_privileges
WHERE table_schema = 'public'
    AND table_name = 'chats'
ORDER BY privilege_type, grantee;

-- Verify RLS policies are still in place
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd
FROM pg_policies
WHERE schemaname = 'public'
    AND tablename = 'chats'
ORDER BY policyname;