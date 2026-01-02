-- Check if the perform_event_matching function exists and is up to date
SELECT
    proname,
    pg_get_function_identity_arguments(oid) as arguments,
    obj_description(oid, 'pg_proc') as description
FROM pg_proc
WHERE proname = 'perform_event_matching';