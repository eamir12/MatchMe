-- Admin Broadcast System Migration
-- Creates tables and functions for admin message broadcasting with FCM integration

-- Create admin broadcasts table
CREATE TABLE IF NOT EXISTS admin_broadcasts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    message_type TEXT DEFAULT 'info' CHECK (message_type IN ('info', 'warning', 'promotion', 'update')),
    
    -- Clickable URL support
    action_url TEXT,
    action_url_text TEXT DEFAULT 'Learn More',
    
    -- Scheduling
    scheduled_at TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'scheduled', 'sending', 'sent', 'failed')),
    
    -- Filtering criteria (JSON for flexibility)
    filter_criteria JSONB DEFAULT '{}',
    
    -- Target counts
    target_user_count INTEGER,
    actual_sent_count INTEGER DEFAULT 0,
    
    -- Admin info
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create broadcast delivery tracking table
CREATE TABLE IF NOT EXISTS admin_broadcast_deliveries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    broadcast_id UUID REFERENCES admin_broadcasts(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    fcm_token TEXT,
    delivery_status TEXT DEFAULT 'pending' CHECK (delivery_status IN ('pending', 'sent', 'delivered', 'failed')),
    delivered_at TIMESTAMPTZ,
    failure_reason TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create notification queue table for FCM integration
CREATE TABLE IF NOT EXISTS notification_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    fcm_token TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    data JSONB DEFAULT '{}',
    platform TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'sent', 'failed')),
    attempts INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    failure_reason TEXT,
    scheduled_at TIMESTAMPTZ DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Note: Using existing users.is_admin column for admin permissions instead of separate table

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_status ON admin_broadcasts(status);
CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_scheduled_at ON admin_broadcasts(scheduled_at);
CREATE INDEX IF NOT EXISTS idx_admin_broadcast_deliveries_broadcast_id ON admin_broadcast_deliveries(broadcast_id);
CREATE INDEX IF NOT EXISTS idx_admin_broadcast_deliveries_user_id ON admin_broadcast_deliveries(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_broadcast_deliveries_status ON admin_broadcast_deliveries(delivery_status);
CREATE INDEX IF NOT EXISTS idx_notification_queue_status ON notification_queue(status);
CREATE INDEX IF NOT EXISTS idx_notification_queue_scheduled_at ON notification_queue(scheduled_at);

-- Enable RLS
ALTER TABLE admin_broadcasts ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_broadcast_deliveries ENABLE ROW LEVEL SECURITY;
-- Disable RLS for notification_queue since it's managed by service role
-- ALTER TABLE notification_queue ENABLE ROW LEVEL SECURITY;

-- RLS Policies
-- Drop existing policies if they exist (to handle re-runs)
DROP POLICY IF EXISTS "Admins can manage broadcasts" ON admin_broadcasts;
DROP POLICY IF EXISTS "Users can view own deliveries" ON admin_broadcast_deliveries;

-- Admin broadcasts: Only admins can create/manage
CREATE POLICY "Admins can manage broadcasts" ON admin_broadcasts
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM users 
      WHERE id = auth.uid() 
      AND is_admin = true
    )
  );

-- Broadcast deliveries: Users can only see their own
CREATE POLICY "Users can view own deliveries" ON admin_broadcast_deliveries
  FOR SELECT USING (user_id = auth.uid());

-- Note: notification_queue has RLS disabled since it's managed by service role

-- Function to get users matching filter criteria
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

-- Function to count target users
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

-- Function to queue FCM notification
CREATE OR REPLACE FUNCTION queue_fcm_notification(
    p_user_id UUID,
    p_fcm_token TEXT,
    p_title TEXT,
    p_body TEXT,
    p_data JSONB DEFAULT '{}',
    p_platform TEXT DEFAULT 'unknown'
)
RETURNS UUID AS $$
DECLARE
    notification_id UUID;
BEGIN
    INSERT INTO notification_queue (
        user_id, fcm_token, title, body, data, platform
    ) VALUES (
        p_user_id, p_fcm_token, p_title, p_body, p_data, p_platform
    ) RETURNING id INTO notification_id;
    
    RETURN notification_id;
END;
$$ LANGUAGE plpgsql;

-- Function to send admin broadcast
CREATE OR REPLACE FUNCTION send_admin_broadcast(broadcast_id UUID)
RETURNS VOID AS $$
DECLARE
    broadcast_record admin_broadcasts%ROWTYPE;
    target_user RECORD;
    notification_count INTEGER := 0;
BEGIN
    SELECT * INTO broadcast_record FROM admin_broadcasts WHERE id = broadcast_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Broadcast not found';
    END IF;
    
    -- Update status to sending
    UPDATE admin_broadcasts 
    SET status = 'sending', sent_at = NOW() 
    WHERE id = broadcast_id;
    
    -- Get target users and queue notifications
    FOR target_user IN SELECT * FROM get_users_for_broadcast(broadcast_record.filter_criteria)
    LOOP
        -- Insert delivery record
        INSERT INTO admin_broadcast_deliveries (broadcast_id, user_id, fcm_token)
        VALUES (broadcast_id, target_user.user_id, target_user.fcm_token);
        
        -- Queue FCM message with clickable URL support
        PERFORM queue_fcm_notification(
            target_user.user_id,
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
        
        notification_count := notification_count + 1;
    END LOOP;
    
    -- Update final counts and status
    UPDATE admin_broadcasts 
    SET 
        target_user_count = notification_count,
        actual_sent_count = notification_count,
        status = 'sent'
    WHERE id = broadcast_id;
    
    -- Clean up old notification queue entries (older than 7 days)
    DELETE FROM notification_queue 
    WHERE created_at < NOW() - INTERVAL '7 days' 
    AND status IN ('sent', 'failed');
    
END;
$$ LANGUAGE plpgsql;

-- Function to mark broadcast as failed
CREATE OR REPLACE FUNCTION mark_broadcast_failed(broadcast_id UUID, failure_reason TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE admin_broadcasts 
    SET status = 'failed', updated_at = NOW()
    WHERE id = broadcast_id;
    
    -- Mark all pending deliveries as failed
    UPDATE admin_broadcast_deliveries 
    SET delivery_status = 'failed', failure_reason = failure_reason
    WHERE broadcast_id = broadcast_id AND delivery_status = 'pending';
END;
$$ LANGUAGE plpgsql;

-- Function to get broadcast statistics
CREATE OR REPLACE FUNCTION get_broadcast_stats(broadcast_id UUID)
RETURNS TABLE(
    total_target INTEGER,
    sent_count INTEGER,
    delivered_count INTEGER,
    failed_count INTEGER,
    delivery_rate NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*) as total_target,
        COUNT(*) FILTER (WHERE delivery_status = 'sent') as sent_count,
        COUNT(*) FILTER (WHERE delivery_status = 'delivered') as delivered_count,
        COUNT(*) FILTER (WHERE delivery_status = 'failed') as failed_count,
        ROUND(
            (COUNT(*) FILTER (WHERE delivery_status = 'delivered')::NUMERIC / 
             NULLIF(COUNT(*), 0) * 100), 2
        ) as delivery_rate
    FROM admin_broadcast_deliveries
    WHERE broadcast_id = broadcast_id;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_admin_broadcasts_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop existing trigger if it exists
DROP TRIGGER IF EXISTS trigger_update_admin_broadcasts_updated_at ON admin_broadcasts;

CREATE TRIGGER trigger_update_admin_broadcasts_updated_at
    BEFORE UPDATE ON admin_broadcasts
    FOR EACH ROW
    EXECUTE FUNCTION update_admin_broadcasts_updated_at();

-- Grant necessary permissions (adjust based on your setup)
GRANT SELECT ON admin_broadcasts TO authenticated;
GRANT SELECT ON admin_broadcast_deliveries TO authenticated;
GRANT SELECT ON notification_queue TO authenticated;

-- Grant full permissions to service role for notification_queue
GRANT ALL ON notification_queue TO service_role;
GRANT ALL ON admin_broadcasts TO service_role;
GRANT ALL ON admin_broadcast_deliveries TO service_role;

-- Note: updated_at is handled manually in process_notification_queue function to avoid trigger issues

-- Grant execution permissions on functions
GRANT EXECUTE ON FUNCTION get_users_for_broadcast(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION count_target_users(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION queue_fcm_notification(UUID, TEXT, TEXT, TEXT, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION send_admin_broadcast(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_broadcast_stats(UUID) TO authenticated;


-- Add comments for documentation
COMMENT ON TABLE admin_broadcasts IS 'Stores admin broadcast messages with scheduling and filtering';
COMMENT ON TABLE admin_broadcast_deliveries IS 'Tracks delivery status of broadcast messages to users';
COMMENT ON TABLE notification_queue IS 'Queue for tracking FCM notification status and delivery';
COMMENT ON COLUMN admin_broadcasts.action_url IS 'Optional URL for user action in broadcast message';
COMMENT ON COLUMN admin_broadcasts.action_url_text IS 'Text to display for the action URL button';
COMMENT ON COLUMN admin_broadcasts.filter_criteria IS 'JSONB object defining user filtering criteria';

-- Note: Admin permissions are managed through the existing users.is_admin column

-- Function to process pending notifications from the queue
-- This function processes pending notifications and updates their status
CREATE OR REPLACE FUNCTION process_notification_queue()
RETURNS INTEGER AS $$
DECLARE
    notification_record RECORD;
    processed_count INTEGER := 0;
    success BOOLEAN;
BEGIN
    -- Process all pending notifications
    FOR notification_record IN 
        SELECT * FROM notification_queue 
        WHERE status = 'pending' 
        ORDER BY created_at ASC
        LIMIT 100 -- Process up to 100 notifications at a time
    LOOP
        -- Update status to processing
        UPDATE notification_queue 
        SET status = 'processing',
            updated_at = NOW()
        WHERE id = notification_record.id;
        
        -- Simulate FCM notification sending (in production, this would call FCM API)
        -- For now, we'll assume success since the actual FCM integration happens on the client side
        success := TRUE;
        
        IF success THEN
            -- Mark as sent successfully
            UPDATE notification_queue 
            SET status = 'sent', 
                sent_at = NOW(),
                updated_at = NOW()
            WHERE id = notification_record.id;
            
            processed_count := processed_count + 1;
        ELSE
            -- Mark as failed
            UPDATE notification_queue 
            SET status = 'failed', 
                failure_reason = 'FCM API error',
                updated_at = NOW()
            WHERE id = notification_record.id;
        END IF;
    END LOOP;
    
    RETURN processed_count;
END;
$$ LANGUAGE plpgsql;

-- Grant execution permissions on the new function
GRANT EXECUTE ON FUNCTION process_notification_queue() TO authenticated;
GRANT EXECUTE ON FUNCTION process_notification_queue() TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION process_notification_queue() IS 'Processes pending notifications from the notification queue and updates their status';