-- Admin Broadcast Functions
-- These functions handle user filtering and broadcast sending

-- Function to get users matching filter criteria
CREATE OR REPLACE FUNCTION get_users_for_broadcast(filter_criteria JSONB)
RETURNS TABLE(user_id UUID, fcm_token TEXT, platform TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT 
        u.id, 
        us.metadata->>'fcm_token' as fcm_token,
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
            
            -- Subscription tier filter
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

-- Function to count target users for a broadcast
CREATE OR REPLACE FUNCTION count_target_users(filter_criteria JSONB)
RETURNS INTEGER AS $$
DECLARE
    user_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO user_count
    FROM get_users_for_broadcast(filter_criteria);
    RETURN user_count;
END;
$$ LANGUAGE plpgsql;

-- Function to send broadcast to target users
CREATE OR REPLACE FUNCTION send_admin_broadcast(broadcast_id UUID)
RETURNS JSON AS $$
DECLARE
    broadcast_record admin_broadcasts%ROWTYPE;
    target_user RECORD;
    delivery_count INTEGER := 0;
    error_count INTEGER := 0;
    result JSON;
BEGIN
    -- Get broadcast record
    SELECT * INTO broadcast_record FROM admin_broadcasts WHERE id = broadcast_id;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Broadcast not found');
    END IF;
    
    -- Update status to sending
    UPDATE admin_broadcasts 
    SET status = 'sending', sent_at = NOW() 
    WHERE id = broadcast_id;
    
    -- Process each target user
    FOR target_user IN SELECT * FROM get_users_for_broadcast(broadcast_record.filter_criteria)
    LOOP
        BEGIN
            -- Insert delivery record
            INSERT INTO admin_broadcast_deliveries (broadcast_id, user_id, fcm_token)
            VALUES (broadcast_id, target_user.user_id, target_user.fcm_token);
            
            -- Queue FCM message using existing notification system
            PERFORM queue_fcm_notification(
                target_user.fcm_token,
                broadcast_record.title,
                broadcast_record.message,
                jsonb_build_object(
                    'type', 'admin_broadcast',
                    'broadcast_id', broadcast_id,
                    'action_url', broadcast_record.action_url,
                    'action_url_text', broadcast_record.action_url_text
                ),
                target_user.platform
            );
            
            delivery_count := delivery_count + 1;
            
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue with other users
            error_count := error_count + 1;
            INSERT INTO admin_broadcast_deliveries (broadcast_id, user_id, fcm_token, delivery_status, failure_reason)
            VALUES (broadcast_id, target_user.user_id, target_user.fcm_token, 'failed', SQLERRM);
        END;
    END LOOP;
    
    -- Update broadcast with final counts and status
    UPDATE admin_broadcasts 
    SET 
        actual_sent_count = delivery_count,
        status = CASE WHEN error_count > 0 AND delivery_count = 0 THEN 'failed' ELSE 'sent' END,
        updated_at = NOW()
    WHERE id = broadcast_id;
    
    RETURN json_build_object(
        'success', true,
        'target_users', delivery_count + error_count,
        'sent_count', delivery_count,
        'error_count', error_count
    );
END;
$$ LANGUAGE plpgsql;

-- Function to queue FCM notification (integrates with existing system)
CREATE OR REPLACE FUNCTION queue_fcm_notification(
    p_fcm_token TEXT,
    p_title TEXT,
    p_body TEXT,
    p_data JSONB,
    p_platform TEXT DEFAULT 'unknown'
)
RETURNS VOID AS $$
BEGIN
    -- This function integrates with your existing notification system
    -- It should call your current FCM sending logic
    
    -- For now, we'll insert into a queue table that your background service can process
    INSERT INTO notification_queue (fcm_token, title, body, data, platform, created_at)
    VALUES (p_fcm_token, p_title, p_body, p_data, p_platform, NOW());
    
    -- You can also directly call your existing FCM service here if preferred
END;
$$ LANGUAGE plpgsql;

-- Create notification queue table if it doesn't exist
CREATE TABLE IF NOT EXISTS notification_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fcm_token TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    data JSONB DEFAULT '{}',
    platform TEXT DEFAULT 'unknown',
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    error_message TEXT
);

CREATE INDEX IF NOT EXISTS idx_notification_queue_status ON notification_queue(status) WHERE status = 'pending';