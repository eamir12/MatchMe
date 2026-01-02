-- Update the get_online_users_count function to use a 30-second window instead of 5 minutes
-- This ensures we detect offline users quickly when connectivity is lost

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