-- Enable realtime on user_activity table for immediate online/offline updates
-- Check if already enabled first to avoid errors
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

-- Verify realtime is enabled
SELECT
    schemaname,
    tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
    AND tablename = 'user_activity';