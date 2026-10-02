-- Restore SELECT permission on chat_messages for authenticated users
-- The RLS policies ensure users can only view messages from their matches
-- This fixes the "permission denied for table chat_messages" error

-- Grant SELECT back to authenticated users
GRANT SELECT ON TABLE public.chat_messages TO authenticated;

-- Grant SELECT to anon as well (for unauthenticated access if needed)
GRANT SELECT ON TABLE public.chat_messages TO anon;

-- Ensure all other permissions are still granted
GRANT INSERT, UPDATE, DELETE ON TABLE public.chat_messages TO authenticated;

-- Verify the permissions
SELECT
    table_name,
    privilege_type,
    grantee
FROM information_schema.table_privileges
WHERE table_schema = 'public'
    AND table_name = 'chat_messages'
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
    AND tablename = 'chat_messages'
ORDER BY policyname;