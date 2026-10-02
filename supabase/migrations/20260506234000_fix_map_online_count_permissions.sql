-- Fix permissions for map online count functions
-- These functions are used by the online world map

-- Grant EXECUTE to authenticated for get_online_user_counts_by_country
GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;

-- Also grant to anon if needed for public access
GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO anon;

-- Verify permissions
SELECT
    routine_name,
    privilege_type,
    grantee
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
    AND routine_name = 'get_online_user_counts_by_country'
    AND privilege_type = 'EXECUTE'
ORDER BY grantee;