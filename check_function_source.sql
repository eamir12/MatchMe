-- Check if perform_event_matching function exists
SELECT
    proname,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description
FROM pg_proc
WHERE proname = 'perform_event_matching';

-- Also check if perform_event_matching_debug exists
SELECT
    proname,
    pg_get_function_identity_arguments(oid) as arguments
FROM pg_proc
WHERE proname = 'perform_event_matching_debug';