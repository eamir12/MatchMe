-- Fix online count functions permissions and verify current state

-- Grant EXECUTE to authenticated for online count functions
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO authenticated;

-- Grant EXECUTE to anon for public access (if needed)
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO anon;

-- Verify permissions
SELECT
    routine_name,
    privilege_type,
    grantee
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
    AND routine_name IN ('get_online_users_count', 'get_online_users_count_excluding_self', 'get_nearby_users_count')
    AND privilege_type = 'EXECUTE'
ORDER BY routine_name, grantee;

-- Debug: Check current online users
SELECT
    user_id,
    is_online,
    is_visible,
    last_activity,
    updated_at,
    NOW() as current_time,
    EXTRACT(EPOCH FROM (NOW() - last_activity)) as seconds_since_activity
FROM user_activity
WHERE is_online = true
ORDER BY last_activity DESC;