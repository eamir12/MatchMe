-- Check grants on sponsored campaign functions
SELECT p.proname, pg_get_function_identity_arguments(p.oid) as args, 
       pg_get_userbyid(a.grantee) as grantee, a.privilege_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN aclexplode(COALESCE(p.proacl, '{}'::aclitem[])) a ON true
WHERE n.nspname = 'public' 
  AND p.proname LIKE 'admin_list_sponsored%'
ORDER BY p.proname;