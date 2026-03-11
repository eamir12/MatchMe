-- Query to check if the correct check_unread_notifications function is applied
-- This should show the updated function that counts chats instead of messages

-- 1. Check the function definition
SELECT
    proname as function_name,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description
FROM pg_proc
WHERE proname = 'check_unread_notifications';

-- 2. Check the actual function source code (look for key indicators)
SELECT
    proname as function_name,
    pg_get_functiondef(oid) as function_definition
FROM pg_proc
WHERE proname = 'check_unread_notifications';

-- 3. Quick test: Check if the function returns the expected structure
-- This should return the column names from the function
SELECT
    attname as column_name,
    atttypid::regtype as data_type
FROM pg_attribute
WHERE attrelid = (
    SELECT oid FROM pg_proc WHERE proname = 'check_unread_notifications'
)::regclass
AND attnum > 0
ORDER BY attnum;

-- 4. Test the function with a real user ID (replace with actual user ID)
-- Look for: unread_messages_count should be number of chats, not messages
-- SELECT * FROM check_unread_notifications('your-user-id-here');


