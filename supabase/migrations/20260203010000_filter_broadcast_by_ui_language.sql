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
            (filter_criteria->'gender' IS NULL OR
             u.gender = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'gender')))) AND
            (filter_criteria->'age_range' IS NULL OR
             (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (filter_criteria->'age_range'->>'min')::int AND
              EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (filter_criteria->'age_range'->>'max')::int)) AND
            (filter_criteria->'subscription_tiers' IS NULL OR
             u.subscription_tier = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'subscription_tiers')))) AND
            (filter_criteria->'verification_status' IS NULL OR
             u.verification_status = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'verification_status')))) AND
            (filter_criteria->'platform' IS NULL OR
             us.platform = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'platform')))) AND
            (filter_criteria->'last_active_days' IS NULL OR
             us.last_active_at >= NOW() - INTERVAL '1 day' * (filter_criteria->>'last_active_days')::int) AND
            (filter_criteria->'visible_only' IS NULL OR
             (filter_criteria->>'visible_only')::boolean = false OR
             u.system_visibility_status = 'visible') AND
            (
              filter_criteria->'ui_language' IS NULL OR
              lower(coalesce(u.preferred_language, '')) = lower(filter_criteria->>'ui_language')
            ) AND
            (
              filter_criteria->'ui_languages' IS NULL OR
              lower(coalesce(u.preferred_language, '')) = ANY(
                ARRAY(
                  SELECT lower(jsonb_array_elements_text(filter_criteria->'ui_languages'))
                )
              )
            )
        )
    );
END;
$$ LANGUAGE plpgsql;
