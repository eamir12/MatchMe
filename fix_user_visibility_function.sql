-- Quick fix for the user_visibility table issue
-- This script fixes the get_users_for_broadcast function to use existing user attributes

-- Fix the get_users_for_broadcast function
CREATE OR REPLACE FUNCTION get_users_for_broadcast(filter_criteria JSONB)
RETURNS TABLE(user_id UUID, fcm_token TEXT, platform TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT u.id, us.metadata->>'fcm_token', us.platform
    FROM users u
    JOIN user_session us ON u.id = us.user_id
    WHERE us.revoked = false 
    AND us.metadata->>'fcm_token' IS NOT NULL
    AND (
        (filter_criteria->>'all_users')::boolean = true OR
        (
            -- Gender filter
            (filter_criteria->'gender' IS NULL OR 
             u.gender = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'gender')))) AND
            
            -- Age filter (calculate age from date_of_birth)
            (filter_criteria->'age_range' IS NULL OR 
             (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (filter_criteria->'age_range'->>'min')::int AND 
              EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (filter_criteria->'age_range'->>'max')::int)) AND
            
            -- Subscription tier filter
            (filter_criteria->'subscription_tiers' IS NULL OR 
             u.subscription_tier = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'subscription_tiers')))) AND
            
            -- Verification status filter (using verification_status from user_verification migration)
            (filter_criteria->'verification_status' IS NULL OR 
             u.verification_status = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'verification_status')))) AND
            
            -- Platform filter
            (filter_criteria->'platform' IS NULL OR 
             us.platform = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'platform')))) AND
            
            -- Last active filter
            (filter_criteria->'last_active_days' IS NULL OR 
             us.last_active_at >= NOW() - INTERVAL '1 day' * (filter_criteria->>'last_active_days')::int) AND
            
            -- Visibility filter (check if user is currently visible using system_visibility_status)
            (filter_criteria->'visible_only' IS NULL OR 
             (filter_criteria->>'visible_only')::boolean = false OR
             u.system_visibility_status = 'visible')
        )
    );
END;
$$ LANGUAGE plpgsql;

-- Test the fixed function
SELECT 'Testing fixed function...' as status;

-- Test 1: All users
SELECT 'All users count:' as test_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"all_users": true}'::jsonb);

-- Test 2: Visible users only
SELECT 'Visible users count:' as test_type, COUNT(*) as user_count  
FROM get_users_for_broadcast('{"visible_only": true}'::jsonb);

-- Test 3: Combined filters (example)
SELECT 'Female Gold users aged 18-25:' as test_type, COUNT(*) as user_count
FROM get_users_for_broadcast('{"gender": ["female"], "subscription_tiers": ["gold"], "age_range": {"min": 18, "max": 25}}'::jsonb);

-- Show sample results
SELECT u.id, u.email, u.gender, u.subscription_tier, 
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) as age,
       u.system_visibility_status
FROM get_users_for_broadcast('{"gender": ["female"], "visible_only": true}'::jsonb) f
JOIN users u ON u.id = f.user_id
LIMIT 5;