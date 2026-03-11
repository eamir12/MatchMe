-- Secure Function to Claim a Referral Code
-- Encapsulates all business logic and anti-abuse checks on the server side.

CREATE OR REPLACE FUNCTION claim_referral(
    p_referral_code TEXT,
    p_device_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER -- Runs with privileges of the function creator (admin)
AS $$
DECLARE
    v_user_id UUID;
    v_user_created_at TIMESTAMPTZ;
    v_referrer_id UUID;
    v_existing_referral_id UUID;
    v_device_check_id UUID;
BEGIN
    -- 1. Get Current User ID (from Auth context)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
    END IF;

    -- 2. Get User Creation Time
    SELECT created_at INTO v_user_created_at FROM users WHERE id = v_user_id;
    
    -- CHECK: Account Age (Must be < 1 hour old)
    -- Allow a small buffer, but strictly block older accounts
    IF v_user_created_at < (NOW() - INTERVAL '1 hour') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account is not new (created > 1 hour ago)');
    END IF;

    -- 3. Validate Referral Code & Get Referrer
    SELECT id INTO v_referrer_id FROM users WHERE referral_code = p_referral_code;
    
    IF v_referrer_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid referral code');
    END IF;

    -- CHECK: Self-Referral
    IF v_referrer_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Cannot refer yourself');
    END IF;

    -- 4. Check for Existing Referral (User Level)
    SELECT id INTO v_existing_referral_id FROM referrals WHERE referee_id = v_user_id;
    IF v_existing_referral_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User already referred');
    END IF;

    -- 5. Check for Device Abuse (Device Level)
    -- If p_device_id is provided and valid, check if it has been used before
    IF p_device_id IS NOT NULL AND p_device_id != 'unknown' AND p_device_id != '' THEN
        SELECT id INTO v_device_check_id FROM referrals WHERE device_id = p_device_id LIMIT 1;
        
        IF v_device_check_id IS NOT NULL THEN
             RETURN jsonb_build_object('success', false, 'error', 'Device already used for referral');
        END IF;
    END IF;

    -- 6. Execute Claim (Insert)
    INSERT INTO referrals (referrer_id, referee_id, status, device_id)
    VALUES (v_referrer_id, v_user_id, 'pending', p_device_id);

    RETURN jsonb_build_object('success', true, 'message', 'Referral claimed successfully');

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
