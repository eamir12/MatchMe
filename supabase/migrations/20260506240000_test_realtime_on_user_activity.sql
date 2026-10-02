-- Test if realtime is properly configured on user_activity table
-- This will help diagnose why realtime events aren't being received

-- Check if user_activity is in the realtime publication
SELECT
    schemaname,
    tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
    AND tablename = 'user_activity';

-- Check if there are any replication slots that might be blocking realtime
SELECT
    slot_name,
    slot_type,
    active,
    restart_lsn
FROM pg_replication_slots
WHERE slot_type IN ('logical', 'physical');

-- Test trigger by manually inserting a record (this should trigger a realtime event)
-- Replace with your actual user ID
-- INSERT INTO user_activity (user_id, last_activity, is_online, is_visible, updated_at)
-- VALUES ('YOUR_USER_ID_HERE', NOW(), true, true, NOW())
-- ON CONFLICT (user_id) DO UPDATE SET
--     last_activity = NOW(),
--     is_online = true,
--     updated_at = NOW();

-- Check the current state of user_activity
SELECT
    user_id,
    is_online,
    is_visible,
    last_activity,
    updated_at
FROM user_activity
ORDER BY updated_at DESC
LIMIT 10;