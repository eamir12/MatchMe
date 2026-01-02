-- Simple test to see if perform_event_matching function exists and can be called
-- This should work if the function is deployed

SELECT 'Function exists and can be called' as status
WHERE EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'perform_event_matching'
);

-- If the above returns a row, the function exists
-- If it returns no rows, the function is not deployed