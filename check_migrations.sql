-- Verification queries for the check_unread_notifications fix
-- (migration 20262126000000_fix_check_unread_notifications_encrypted.sql).
-- Run these in the Supabase SQL editor after applying migrations.

-- 1. Overloads present: expect exactly ONE row, args like "uuid, uuid DEFAULT NULL".
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname = 'check_unread_notifications';

-- 2. Broken plaintext references still installed: expect ZERO rows.
--    (Any row here means an old definition still references removed columns
--     and every call raises 42703 / HTTP 400.)
SELECT proname
FROM pg_proc
WHERE proname = 'check_unread_notifications'
  AND (
    pg_get_functiondef(oid) LIKE '%content_translated%'
    OR pg_get_functiondef(oid) LIKE '%content_original%'
  );

-- 3. Grants: expect authenticated + service_role (and postgres), NOT anon/PUBLIC.
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_name = 'check_unread_notifications';

-- 4. Live smoke test (replace with a real user id; run as that user or with
--    the service role). Expect: no error; when unread_messages_count > 0,
--    latest_message_content = 'Sent a message' and the translation flags NULL.
-- SELECT * FROM check_unread_notifications('<user-uuid>'::uuid);
