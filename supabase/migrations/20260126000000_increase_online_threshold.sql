-- Increase the online threshold to 60 seconds to prevent flickering
-- and ensure users remain online even if there are slight network delays or background service throttling.

CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who have been active within the last 60 seconds (increased from 30s)
    -- This includes both visible and invisible users
    SELECT COUNT(*)
    INTO online_count
    FROM user_activity ua
    WHERE ua.last_activity > NOW() - INTERVAL '60 seconds'
    AND ua.is_online = true;

    RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;
