-- Ensure user_activity table has proper permissions for realtime subscriptions
-- Authenticated users need SELECT permission to receive realtime events

-- Grant SELECT on user_activity to authenticated users
GRANT SELECT ON TABLE public.user_activity TO authenticated;

-- Grant SELECT on user_activity to anon (for unauthenticated users if needed)
GRANT SELECT ON TABLE public.user_activity TO anon;

-- Ensure realtime is enabled on user_activity
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
            AND tablename = 'user_activity'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE user_activity;
        RAISE NOTICE 'user_activity added to supabase_realtime publication';
    ELSE
        RAISE NOTICE 'user_activity already in supabase_realtime publication';
    END IF;
END $$;

-- Verify permissions
SELECT
    table_name,
    privilege_type,
    grantee
FROM information_schema.table_privileges
WHERE table_schema = 'public'
    AND table_name = 'user_activity'
    AND privilege_type = 'SELECT'
ORDER BY grantee;

-- Verify realtime is enabled
SELECT
    schemaname,
    tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
    AND tablename = 'user_activity';