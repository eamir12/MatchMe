-- Create trigger to automatically perform user proximity matching when locations are updated
-- This provides immediate reactive matching in addition to the periodic continuous matching

CREATE OR REPLACE FUNCTION trigger_perform_user_location_matching()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';

    -- Only trigger on INSERT or UPDATE (when location is added/updated)
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        -- Call the continuous user matching function
        -- This will check for matches involving the user who just updated their location
        PERFORM perform_continuous_user_matching();
    END IF;

    RETURN NEW;
END;
$$;

-- Create the trigger on user_locations table
DROP TRIGGER IF EXISTS trigger_user_location_matching ON user_locations;
CREATE TRIGGER trigger_user_location_matching
    AFTER INSERT OR UPDATE ON user_locations
    FOR EACH STATEMENT  -- Use STATEMENT level to avoid multiple calls for the same user
    EXECUTE FUNCTION trigger_perform_user_location_matching();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION trigger_perform_user_location_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_perform_user_location_matching() TO anon;
