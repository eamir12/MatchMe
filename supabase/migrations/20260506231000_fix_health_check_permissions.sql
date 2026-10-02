-- Fix health_check permissions for connectivity monitoring
-- This function is called by the Flutter app to check backend health

-- Grant EXECUTE to anon (for unauthenticated health checks)
GRANT EXECUTE ON FUNCTION public.health_check() TO anon;

-- Grant EXECUTE to authenticated (for authenticated health checks)
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;

-- Verify permissions
SELECT
    routine_name,
    privilege_type,
    grantee
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
    AND routine_name = 'health_check'
    AND privilege_type = 'EXECUTE'
ORDER BY grantee, routine_name;