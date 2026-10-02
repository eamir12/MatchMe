-- Fix RLS ambiguity by adding row_security = off to SECURITY DEFINER functions
-- These functions bypass RLS because they have their own authorization checks

-- Drop functions first
DROP FUNCTION IF EXISTS public.admin_create_promo_code(
  TEXT, TEXT, TEXT, INT, INT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT
);

DROP FUNCTION IF EXISTS public.redeem_promo_code(TEXT, UUID, UUID, INT);

DROP FUNCTION IF EXISTS public.admin_update_promo_code(UUID, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT);

-- Recreate admin_create_promo_code with row_security = off
CREATE OR REPLACE FUNCTION public.admin_create_promo_code(
  p_code TEXT,
  p_description TEXT,
  p_code_type TEXT,
  p_discount_percent INT DEFAULT NULL,
  p_discount_amount_cents INT DEFAULT NULL,
  p_free_days INT DEFAULT NULL,
  p_upgrade_tier TEXT DEFAULT NULL,
  p_applicable_tiers TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_campaign_name TEXT DEFAULT NULL,
  p_max_uses INT DEFAULT NULL,
  p_max_uses_per_user INT DEFAULT 1,
  p_valid_from TIMESTAMPTZ DEFAULT now(),
  p_valid_until TIMESTAMPTZ DEFAULT (now() + INTERVAL '90 days'),
  p_min_tier TEXT DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  code TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
  v_code_id UUID;
BEGIN
  -- Check admin status
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id AND is_admin = true) THEN
    RAISE EXCEPTION 'Only admins can create promo codes';
  END IF;

  -- Validate inputs
  IF p_code IS NULL OR TRIM(p_code) = '' THEN
    RAISE EXCEPTION 'Code is required';
  END IF;

  IF p_code_type NOT IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade') THEN
    RAISE EXCEPTION 'Invalid code type';
  END IF;

  -- Insert new promo code
  INSERT INTO public.promo_codes (
    code,
    description,
    code_type,
    discount_percent,
    discount_amount_cents,
    free_days,
    upgrade_tier,
    applicable_tiers,
    min_tier,
    campaign_name,
    max_uses,
    max_uses_per_user,
    valid_from,
    valid_until,
    created_by,
    is_active
  )
  VALUES (
    UPPER(TRIM(p_code)),
    p_description,
    p_code_type,
    p_discount_percent,
    p_discount_amount_cents,
    p_free_days,
    p_upgrade_tier,
    p_applicable_tiers,
    p_min_tier,
    p_campaign_name,
    p_max_uses,
    p_max_uses_per_user,
    p_valid_from,
    p_valid_until,
    v_user_id,
    true
  )
  RETURNING public.promo_codes.id INTO v_code_id;

  RETURN QUERY SELECT v_code_id, UPPER(TRIM(p_code)), now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_promo_code(
  TEXT, TEXT, TEXT, INT, INT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) TO authenticated;

-- Recreate redeem_promo_code with row_security = off
CREATE OR REPLACE FUNCTION public.redeem_promo_code(
  p_code TEXT,
  p_user_id UUID DEFAULT NULL,
  p_subscription_queue_id UUID DEFAULT NULL,
  p_discount_value_cents INT DEFAULT 0
)
RETURNS TABLE (
  success BOOLEAN,
  error_message TEXT,
  usage_id UUID,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_code_id UUID;
  v_user_id UUID;
  v_ip_address TEXT;
  v_user_agent TEXT;
  v_usage_id UUID;
  v_max_uses_per_user INT;
  v_current_uses INT;
  v_max_uses INT;
  v_current_global_uses INT;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'User not authenticated', NULL::UUID, 'Not authenticated';
    RETURN;
  END IF;

  -- Get code ID and details
  SELECT id, max_uses_per_user, max_uses
  INTO v_code_id, v_max_uses_per_user, v_max_uses
  FROM public.promo_codes
  WHERE UPPER(code) = UPPER(p_code)
    AND is_active = true
    AND valid_until > now();

  IF v_code_id IS NULL THEN
    RETURN QUERY SELECT false, 'Code not found or expired', NULL::UUID, 'Invalid code';
    RETURN;
  END IF;

  -- Check global max uses
  IF v_max_uses IS NOT NULL THEN
    SELECT COUNT(*) INTO v_current_global_uses
    FROM public.promo_code_usages
    WHERE promo_code_id = v_code_id;

    IF v_current_global_uses >= v_max_uses THEN
      RETURN QUERY SELECT false, 'Code has reached max uses', NULL::UUID, 'This code is no longer available';
      RETURN;
    END IF;
  END IF;

  -- Check per-user max uses
  SELECT COUNT(*) INTO v_current_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id AND user_id = v_user_id;

  IF v_current_uses >= v_max_uses_per_user THEN
    RETURN QUERY SELECT false, 'User has already used this code max times', NULL::UUID, 'You have already used this code';
    RETURN;
  END IF;

  -- Get user IP and user agent (for fraud detection)
  v_ip_address := current_setting('request.headers', true)::json->>'cf-connecting-ip';
  v_user_agent := current_setting('request.headers', true)::json->>'user-agent';

  -- Record usage
  INSERT INTO public.promo_code_usages (
    promo_code_id,
    user_id,
    subscription_queue_id,
    discount_value_cents,
    ip_address,
    user_agent,
    redeemed_at
  )
  VALUES (
    v_code_id,
    v_user_id,
    p_subscription_queue_id,
    p_discount_value_cents,
    v_ip_address,
    v_user_agent,
    now()
  )
  RETURNING id INTO v_usage_id;

  RETURN QUERY SELECT true, '', v_usage_id, 'Promo code redeemed successfully';
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) TO authenticated;

-- Recreate admin_update_promo_code with row_security = off
CREATE OR REPLACE FUNCTION public.admin_update_promo_code(
  p_code_id UUID,
  p_is_active BOOLEAN DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL,
  p_valid_from TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  code TEXT,
  is_active BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Check admin status
  v_user_id := auth.uid();
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id AND is_admin = true) THEN
    RAISE EXCEPTION 'Only admins can update promo codes';
  END IF;

  UPDATE public.promo_codes
  SET
    is_active = COALESCE(p_is_active, is_active),
    valid_until = COALESCE(p_valid_until, valid_until),
    valid_from = COALESCE(p_valid_from, valid_from),
    max_uses = COALESCE(p_max_uses, max_uses),
    updated_at = now()
  WHERE id = p_code_id
  RETURNING public.promo_codes.id, public.promo_codes.code, public.promo_codes.is_active;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_promo_code(UUID, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT) TO authenticated;
