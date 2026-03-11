-- Fix for the ambiguous column reference error
-- Only run this - don't need to recreate the entire table

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
        v_starts_at := v_last_queued_expires_at;
    ELSIF v_current_tier IS NOT NULL AND v_current_tier != 'free' AND v_current_expires_at > NOW() THEN
        v_starts_at := v_current_expires_at;
    ELSE
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
    
    RETURN QUERY SELECT v_queue_id, v_starts_at, v_expires_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Test it
SELECT * FROM add_subscription_to_queue(
    '35fe114e-eae5-49d6-9eba-8459617e7b82',
    'platinum',
    300,
    'manual',
    'test-1',
    '{}'
);
