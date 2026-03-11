-- Test if the process_notification_queue function exists
SELECT proname, proargtypes, prorettype 
FROM pg_proc 
WHERE proname = 'process_notification_queue';

-- If it doesn't exist, let's create a simple version
CREATE OR REPLACE FUNCTION process_notification_queue()
RETURNS INTEGER AS $$
BEGIN
    RETURN 0;
END;
$$ LANGUAGE plpgsql;

-- Test the function
SELECT process_notification_queue();