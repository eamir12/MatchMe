-- Ensure get_online_users_count counts users who are actively online
-- This migration is idempotent and will overwrite any prior incorrect definitions.

CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who have been active within the last 30 seconds and are marked online.
    -- This returns the total number of active users (including the caller).
    SELECT COUNT(*)
    INTO online_count
    FROM user_activity ua
    WHERE ua.last_activity > NOW() - INTERVAL '30 seconds'
      AND ua.is_online = TRUE;

    RETURN COALESCE(online_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;