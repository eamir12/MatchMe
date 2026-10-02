-- Grant EXECUTE on get_user_rating_summary to authenticated
-- This function is used by the app to get user rating summaries

GRANT EXECUTE ON FUNCTION public.get_user_rating_summary(uuid, integer, integer) TO authenticated;

-- Verify permissions
SELECT
    routine_name,
    privilege_type,
    grantee
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
    AND routine_name = 'get_user_rating_summary'
    AND privilege_type = 'EXECUTE'
ORDER BY grantee;