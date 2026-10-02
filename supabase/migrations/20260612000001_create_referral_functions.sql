-- Migration: Create server-side referral functions
-- Replaces client-side code generation and non-atomic credit increment
-- Phase 2: complete_referral — atomic credit grant
-- Phase 3: generate_referral_code — collision-proof code generation

BEGIN;

-- ============================================================
-- Phase 3: generate_referral_code
-- Server-side random code generation with UNIQUE retry.
-- Never trust a client-generated code.
-- ============================================================
CREATE OR REPLACE FUNCTION public.generate_referral_code(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix TEXT;
  v_code TEXT;
  v_attempts INTEGER := 0;
BEGIN
  -- Derive prefix from user's name (first 4 alphanumeric chars)
  SELECT COALESCE(
    LEFT(REGEXP_REPLACE(COALESCE(name, ''), '[^a-zA-Z0-9]', '', 'g'), 4),
    'USER'
  ) INTO v_prefix FROM users WHERE id = p_user_id;

  IF v_prefix IS NULL OR v_prefix = '' THEN
    v_prefix := 'USER';
  END IF;

  LOOP
    v_code := UPPER(v_prefix || SUBSTR(MD5(RANDOM()::TEXT), 1, 4));
    v_attempts := v_attempts + 1;

    IF v_attempts > 20 THEN
      RAISE EXCEPTION 'Could not generate a unique referral code after 20 attempts';
    END IF;

    BEGIN
      UPDATE users
      SET referral_code = v_code
      WHERE id = p_user_id AND referral_code IS NULL;

      IF FOUND THEN
        RETURN v_code;
      END IF;
    EXCEPTION WHEN unique_violation THEN
      -- collision; retry with new random suffix
    END;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.generate_referral_code(UUID) TO authenticated;

-- ============================================================
-- Phase 2: complete_referral
-- Atomically grants referral rewards to both referrer and referee.
-- Uses row-level locking (FOR UPDATE) to prevent race conditions.
-- ============================================================
CREATE OR REPLACE FUNCTION public.complete_referral(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral RECORD;
  v_reward_amount INTEGER;
BEGIN
  -- Find the pending referral where p_user_id is the referee
  SELECT * INTO v_referral
  FROM referrals
  WHERE referee_id = p_user_id AND status = 'pending'
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_pending_referral');
  END IF;

  -- Read reward amount from app_config
  SELECT COALESCE(
    (SELECT config_value::integer FROM app_config WHERE config_key = 'referral.reward_amount'),
    10
  ) INTO v_reward_amount;

  -- Atomic credit increments (no read-then-write race)
  UPDATE users SET credits = COALESCE(credits, 0) + v_reward_amount WHERE id = v_referral.referrer_id;
  UPDATE users SET credits = COALESCE(credits, 0) + v_reward_amount WHERE id = p_user_id;

  -- Mark referral completed
  UPDATE referrals
  SET status = 'completed', completed_at = NOW()
  WHERE id = v_referral.id;

  RETURN jsonb_build_object(
    'success', true,
    'referrer_id', v_referral.referrer_id,
    'referee_id', p_user_id,
    'reward_amount', v_reward_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_referral(UUID) TO authenticated;

COMMIT;
