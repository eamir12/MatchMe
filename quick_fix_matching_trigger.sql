-- Quick fix: Add trigger for immediate user matching on location updates

CREATE OR REPLACE FUNCTION trigger_perform_user_location_matching()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        PERFORM perform_continuous_user_matching();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_user_location_matching ON user_locations;
CREATE TRIGGER trigger_user_location_matching
    AFTER INSERT OR UPDATE ON user_locations
    FOR EACH STATEMENT
    EXECUTE FUNCTION trigger_perform_user_location_matching();

GRANT EXECUTE ON FUNCTION trigger_perform_user_location_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_perform_user_location_matching() TO anon;

-- Test the trigger by running matching
SELECT * FROM perform_continuous_user_matching();
