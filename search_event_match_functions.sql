-- Query to search for functions related to events or matching
SELECT 
    n.nspname as schema_name,
    p.proname as function_name,
    pg_get_function_identity_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type,
    CASE p.prokind
        WHEN 'f' THEN 'function'
        WHEN 'p' THEN 'procedure'
        WHEN 'a' THEN 'aggregate'
        WHEN 'w' THEN 'window'
    END as function_type,
    l.lanname as language,
    p.prosrc as function_body -- This shows the actual function code
FROM pg_proc p
LEFT JOIN pg_namespace n ON p.pronamespace = n.oid
LEFT JOIN pg_language l ON p.prolang = l.oid
WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast')
AND (
    p.proname ILIKE '%event%' 
    OR p.proname ILIKE '%match%'
    OR p.prosrc ILIKE '%event%'
    OR p.prosrc ILIKE '%match%'
    OR p.prosrc ILIKE '%attendee%'
)
ORDER BY p.proname;