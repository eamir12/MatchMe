-- Fix get_online_users_count to be reliable and consistent across all clients
-- Ensure it is SECURITY DEFINER to bypass RLS and count all online users

DROP FUNCTION IF EXISTS get_online_users_count(UUID);

CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    -- Count users who have been active within the last 60 seconds
    -- This includes the current user (p_user_id) if they are online
    SELECT COUNT(*)
    INTO online_count
    FROM user_activity ua
    WHERE ua.last_activity > NOW() - INTERVAL '60 seconds'
    AND ua.is_online = true;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO service_role;
