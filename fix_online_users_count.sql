-- Fix the get_online_users_count function to properly count users who are actually online
-- Instead of counting all users, count users who have updated their location recently

CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who have updated their location within the last 5 minutes
    -- This indicates they are currently active/online in the app
    -- Exclude the current user from the count
    SELECT COUNT(DISTINCT ul.user_id)
    INTO online_count
    FROM user_locations ul
    WHERE ul.updated_at > NOW() - INTERVAL '5 minutes'
    AND ul.user_id != p_user_id;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Grant proper permissions
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;