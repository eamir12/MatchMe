-- Fix the get_users_for_broadcast function to use correct field names
DROP FUNCTION IF EXISTS get_users_for_broadcast(JSONB);

CREATE OR REPLACE FUNCTION get_users_for_broadcast(filter_criteria JSONB)
RETURNS TABLE (
    user_id UUID,
    fcm_token TEXT,
    platform TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT 
        u.id, 
        us.metadata->>'fcm_token', 
        us.platform
    FROM users u
    JOIN user_session us ON u.id = us.user_id
    WHERE us.revoked = false 
    AND us.metadata->>'fcm_token' IS NOT NULL
    AND LENGTH(us.metadata->>'fcm_token') > 10
    AND (
        -- All users filter
        (filter_criteria->>'all_users')::boolean = true OR
        (
            -- Gender filter
            (filter_criteria->'gender' IS NULL OR 
             u.gender = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'gender')))) AND
            
            -- Age range filter (calculate age from date_of_birth)
            (filter_criteria->'age_range' IS NULL OR 
             (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (filter_criteria->'age_range'->>'min')::int AND 
              EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (filter_criteria->'age_range'->>'max')::int)) AND
            
            -- Subscription tier filter (using subscription_tier field)
            (filter_criteria->'subscription_tiers' IS NULL OR 
             u.subscription_tier = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'subscription_tiers')))) AND
            
            -- Verification status filter
            (filter_criteria->'verification_status' IS NULL OR 
             u.verification_status = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'verification_status')))) AND
            
            -- Platform filter
            (filter_criteria->'platform' IS NULL OR 
             us.platform = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'platform')))) AND
            
            -- Last active filter (days)
            (filter_criteria->'last_active_days' IS NULL OR 
             us.last_active_at >= NOW() - INTERVAL '1 day' * (filter_criteria->>'last_active_days')::int) AND
            
            -- Currently visible users filter
            (filter_criteria->'currently_visible' IS NULL OR 
             (filter_criteria->>'currently_visible')::boolean = false OR
             EXISTS (
                 SELECT 1 FROM user_visibility_schedule v
                 WHERE v.user_id = u.id 
                 AND v.is_visible = true
                 AND (v.schedule IS NULL OR NOW() <@ v.schedule)
             ))
        )
    );
END;
$$ LANGUAGE plpgsql;