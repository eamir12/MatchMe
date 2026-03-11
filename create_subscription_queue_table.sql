-- Create subscription queue table to support infinite successive subscriptions
-- This replaces the single 'next' subscription columns in the users table

CREATE TABLE IF NOT EXISTS user_subscription_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tier VARCHAR(50) NOT NULL, -- 'plus', 'gold', 'platinum'
    status VARCHAR(20) NOT NULL DEFAULT 'pending', -- 'pending', 'active', 'completed', 'cancelled'
    starts_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    payment_provider VARCHAR(20), -- 'revenuecat', 'stripe', 'manual'
    transaction_id TEXT, -- Store RevenueCat transaction ID or Stripe payment intent
    purchase_metadata JSONB DEFAULT '{}', -- Store additional purchase info
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    activated_at TIMESTAMPTZ, -- When this subscription became active
    cancelled_at TIMESTAMPTZ, -- When this subscription was cancelled
    cancellation_reason TEXT
);

-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_subscription_queue_user_id ON user_subscription_queue(user_id);
CREATE INDEX IF NOT EXISTS idx_subscription_queue_status ON user_subscription_queue(status);
CREATE INDEX IF NOT EXISTS idx_subscription_queue_starts_at ON user_subscription_queue(starts_at);
CREATE INDEX IF NOT EXISTS idx_subscription_queue_user_status ON user_subscription_queue(user_id, status);

-- Enable RLS
ALTER TABLE user_subscription_queue ENABLE ROW LEVEL SECURITY;

-- Create RLS policies
CREATE POLICY "Users can view their own subscription queue"
    ON user_subscription_queue
    FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own subscription queue entries"
    ON user_subscription_queue
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Function to add a subscription to the queue
CREATE OR REPLACE FUNCTION add_subscription_to_queue(
    p_user_id UUID,
    p_tier VARCHAR,
    p_duration_seconds INTEGER,
    p_payment_provider VARCHAR DEFAULT 'manual',
    p_transaction_id TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS TABLE (
    queue_entry_id UUID,
    starts_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ
) AS $$
DECLARE
    v_starts_at TIMESTAMPTZ;
    v_expires_at TIMESTAMPTZ;
    v_current_tier VARCHAR;
    v_current_expires_at TIMESTAMPTZ;
    v_queue_id UUID;
    v_last_queued_expires_at TIMESTAMPTZ;
BEGIN
    -- Get current subscription info
    SELECT 
        u.subscription_tier,
        u.subscription_expires_at
    INTO 
        v_current_tier,
        v_current_expires_at
    FROM users u
    WHERE u.id = p_user_id;
    
    -- Find the last queued subscription's expiry date
    SELECT MAX(sq.expires_at)
    INTO v_last_queued_expires_at
    FROM user_subscription_queue sq
    WHERE sq.user_id = p_user_id
    AND sq.status IN ('pending', 'active')
    AND sq.expires_at > NOW();
    
    -- Determine when this subscription should start
    IF v_last_queued_expires_at IS NOT NULL THEN
        -- There's already a queued subscription, start after it
        v_starts_at := v_last_queued_expires_at;
    ELSIF v_current_tier IS NOT NULL AND v_current_tier != 'free' AND v_current_expires_at > NOW() THEN
        -- Current subscription is active, start after it
        v_starts_at := v_current_expires_at;
    ELSE
        -- No active or queued subscriptions, start immediately
        v_starts_at := NOW();
    END IF;
    
    -- Calculate expiry
    v_expires_at := v_starts_at + (p_duration_seconds || ' seconds')::INTERVAL;
    
    -- Insert the queue entry
    INSERT INTO user_subscription_queue (
        user_id,
        tier,
        status,
        starts_at,
        expires_at,
        payment_provider,
        transaction_id,
        purchase_metadata
    ) VALUES (
        p_user_id,
        p_tier,
        'pending',
        v_starts_at,
        v_expires_at,
        p_payment_provider,
        p_transaction_id,
        p_metadata
    )
    RETURNING id INTO v_queue_id;
    
    -- Return the created entry info
    RETURN QUERY SELECT v_queue_id, v_starts_at, v_expires_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get the next queued subscription for a user
CREATE OR REPLACE FUNCTION get_next_queued_subscription(p_user_id UUID)
RETURNS TABLE (
    queue_id UUID,
    tier VARCHAR,
    starts_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sq.id,
        sq.tier,
        sq.starts_at,
        sq.expires_at
    FROM user_subscription_queue sq
    WHERE sq.user_id = p_user_id
    AND sq.status = 'pending'
    AND sq.starts_at > NOW()
    ORDER BY sq.starts_at ASC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to normalize subscriptions (activate queued subscriptions when current expires)
CREATE OR REPLACE FUNCTION normalize_user_subscription_v2()
RETURNS TRIGGER AS $$
DECLARE
    v_next_subscription RECORD;
BEGIN
    -- Only run if the current subscription has expired
    IF NEW.subscription_tier IS NOT NULL 
       AND NEW.subscription_tier != 'free'
       AND NEW.subscription_expires_at IS NOT NULL
       AND NEW.subscription_expires_at <= NOW() THEN
        
        -- Find the next pending subscription
        SELECT * INTO v_next_subscription
        FROM user_subscription_queue
        WHERE user_id = NEW.id
        AND status = 'pending'
        AND starts_at <= NOW()
        ORDER BY starts_at ASC
        LIMIT 1;
        
        IF FOUND THEN
            -- Activate the queued subscription
            UPDATE user_subscription_queue
            SET status = 'active',
                activated_at = NOW(),
                updated_at = NOW()
            WHERE id = v_next_subscription.id;
            
            -- Update user's current subscription
            NEW.subscription_tier := v_next_subscription.tier;
            NEW.subscription_expires_at := v_next_subscription.expires_at;
            NEW.updated_at := NOW();
        ELSE
            -- No queued subscription, set to free
            NEW.subscription_tier := 'free';
            NEW.subscription_expires_at := NULL;
            NEW.updated_at := NOW();
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop old trigger if exists
DROP TRIGGER IF EXISTS trigger_normalize_subscription ON users;

-- Create new trigger
CREATE TRIGGER trigger_normalize_subscription_v2
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION normalize_user_subscription_v2();

-- Function to manually trigger subscription normalization
CREATE OR REPLACE FUNCTION trigger_subscription_normalization()
RETURNS VOID AS $$
DECLARE
    v_user RECORD;
    v_next_subscription RECORD;
BEGIN
    -- Find users with expired subscriptions
    FOR v_user IN 
        SELECT id, subscription_tier, subscription_expires_at
        FROM users
        WHERE subscription_tier IS NOT NULL 
        AND subscription_tier != 'free'
        AND subscription_expires_at IS NOT NULL
        AND subscription_expires_at <= NOW()
    LOOP
        -- Find next queued subscription
        SELECT * INTO v_next_subscription
        FROM user_subscription_queue
        WHERE user_id = v_user.id
        AND status = 'pending'
        AND starts_at <= NOW()
        ORDER BY starts_at ASC
        LIMIT 1;
        
        IF FOUND THEN
            -- Activate it
            UPDATE user_subscription_queue
            SET status = 'active',
                activated_at = NOW(),
                updated_at = NOW()
            WHERE id = v_next_subscription.id;
            
            -- Update user
            UPDATE users
            SET subscription_tier = v_next_subscription.tier,
                subscription_expires_at = v_next_subscription.expires_at,
                updated_at = NOW()
            WHERE id = v_user.id;
        ELSE
            -- No queued subscription, downgrade to free
            UPDATE users
            SET subscription_tier = 'free',
                subscription_expires_at = NULL,
                updated_at = NOW()
            WHERE id = v_user.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to cancel a queued subscription
CREATE OR REPLACE FUNCTION cancel_queued_subscription(
    p_queue_id UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE user_subscription_queue
    SET status = 'cancelled',
        cancelled_at = NOW(),
        cancellation_reason = p_reason,
        updated_at = NOW()
    WHERE id = p_queue_id
    AND status = 'pending';
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get user's subscription timeline
CREATE OR REPLACE FUNCTION get_user_subscription_timeline(p_user_id UUID)
RETURNS TABLE (
    entry_type VARCHAR, -- 'current' or 'queued'
    tier VARCHAR,
    status VARCHAR,
    starts_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    payment_provider VARCHAR
) AS $$
DECLARE
    v_current_tier VARCHAR;
    v_current_expires_at TIMESTAMPTZ;
BEGIN
    -- Get current subscription
    SELECT subscription_tier, subscription_expires_at
    INTO v_current_tier, v_current_expires_at
    FROM users
    WHERE id = p_user_id;
    
    -- Return current if exists and not free
    IF v_current_tier IS NOT NULL AND v_current_tier != 'free' THEN
        RETURN QUERY
        SELECT 
            'current'::VARCHAR,
            v_current_tier::VARCHAR,
            'active'::VARCHAR,
            NOW()::TIMESTAMPTZ,
            v_current_expires_at::TIMESTAMPTZ,
            NULL::VARCHAR;
    END IF;
    
    -- Return queued subscriptions
    RETURN QUERY
    SELECT 
        'queued'::VARCHAR,
        sq.tier,
        sq.status,
        sq.starts_at,
        sq.expires_at,
        sq.payment_provider
    FROM user_subscription_queue sq
    WHERE sq.user_id = p_user_id
    AND sq.status IN ('pending', 'active')
    ORDER BY sq.starts_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- AUTOMATIC SUBSCRIPTION NORMALIZATION (CRON JOB)
-- ============================================================================

-- Enable pg_cron extension (if not already enabled)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Create a function to run normalization periodically
CREATE OR REPLACE FUNCTION scheduled_subscription_normalization()
RETURNS VOID AS $$
BEGIN
    PERFORM trigger_subscription_normalization();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Schedule the normalization to run every 5 minutes
-- This handles automatic subscription transitions without requiring client action
SELECT cron.schedule(
    'subscription-normalization',  -- job name
    '*/5 * * * *',                 -- every 5 minutes
    'SELECT scheduled_subscription_normalization()'
);

-- Function to check if pg_cron is working (for debugging)
CREATE OR REPLACE FUNCTION get_subscription_cron_status()
RETURNS TABLE (
    job_name TEXT,
    schedule TEXT,
    active BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        j.jobname::TEXT,
        j.schedule::TEXT,
        j.active
    FROM cron.job j
    WHERE j.jobname = 'subscription-normalization';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- CLIENT-SIDE FALLBACK (for immediate response)
-- ============================================================================

-- Function to check and normalize a specific user's subscription
-- Call this from the client when app opens or periodically
CREATE OR REPLACE FUNCTION check_and_normalize_user_subscription(p_user_id UUID)
RETURNS TABLE (
    previous_tier VARCHAR,
    new_tier VARCHAR,
    normalized BOOLEAN
) AS $$
DECLARE
    v_current_tier VARCHAR;
    v_current_expires_at TIMESTAMPTZ;
    v_next_subscription RECORD;
BEGIN
    -- Get current subscription
    SELECT subscription_tier, subscription_expires_at
    INTO v_current_tier, v_current_expires_at
    FROM users
    WHERE id = p_user_id;
    
    -- Check if current subscription has expired
    IF v_current_tier IS NOT NULL 
       AND v_current_tier != 'free'
       AND v_current_expires_at IS NOT NULL
       AND v_current_expires_at <= NOW() THEN
        
        -- Find next queued subscription
        SELECT * INTO v_next_subscription
        FROM user_subscription_queue
        WHERE user_id = p_user_id
        AND status = 'pending'
        AND starts_at <= NOW()
        ORDER BY starts_at ASC
        LIMIT 1;
        
        IF FOUND THEN
            -- Activate the queued subscription
            UPDATE user_subscription_queue
            SET status = 'active',
                activated_at = NOW(),
                updated_at = NOW()
            WHERE id = v_next_subscription.id;
            
            -- Update user's current subscription
            UPDATE users
            SET subscription_tier = v_next_subscription.tier,
                subscription_expires_at = v_next_subscription.expires_at,
                updated_at = NOW()
            WHERE id = p_user_id;
            
            RETURN QUERY SELECT 
                v_current_tier::VARCHAR,
                v_next_subscription.tier::VARCHAR,
                TRUE;
            RETURN;
        ELSE
            -- No queued subscription, downgrade to free
            UPDATE users
            SET subscription_tier = 'free',
                subscription_expires_at = NULL,
                updated_at = NOW()
            WHERE id = p_user_id;
            
            RETURN QUERY SELECT 
                v_current_tier::VARCHAR,
                'free'::VARCHAR,
                TRUE;
            RETURN;
        END IF;
    END IF;
    
    -- No change needed
    RETURN QUERY SELECT 
        v_current_tier::VARCHAR,
        v_current_tier::VARCHAR,
        FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE user_subscription_queue IS 'Stores queued subscriptions for users, allowing infinite successive subscriptions';
COMMENT ON COLUMN user_subscription_queue.status IS 'pending=waiting for current to expire, active=currently active, completed=finished, cancelled=cancelled before activation';
COMMENT ON FUNCTION add_subscription_to_queue IS 'Adds a new subscription to the queue, automatically calculating start time based on existing subscriptions';
COMMENT ON FUNCTION normalize_user_subscription_v2 IS 'Automatically activates the next queued subscription when current expires (trigger-based)';
COMMENT ON FUNCTION scheduled_subscription_normalization IS 'Scheduled job that runs every 5 minutes to normalize all expired subscriptions';
COMMENT ON FUNCTION check_and_normalize_user_subscription IS 'Client-callable function to check and normalize a specific user subscription immediately';
