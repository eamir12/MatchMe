-- Fix the get_online_users_count function to properly count users who are actually online
-- Count ALL users who have been active recently, including the current user

CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who have been active within the last 30 seconds
    -- This indicates they are currently active/online in the app
    SELECT COUNT(*)
    INTO online_count
    FROM user_activity ua
    WHERE ua.last_activity > NOW() - INTERVAL '30 seconds'
    AND ua.is_online = true;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Grant proper permissions
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;