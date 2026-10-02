-- RPC Functions for Promo Code Management and Validation

BEGIN;

-- Function: validate_promo_code
-- Validates a promo code and returns details if valid
DROP FUNCTION IF EXISTS public.validate_promo_code(TEXT, UUID, TEXT);
CREATE OR REPLACE FUNCTION public.validate_promo_code(
  p_code TEXT,
  p_user_id UUID DEFAULT auth.uid(),
  p_for_tier TEXT DEFAULT NULL
)
RETURNS TABLE (
  valid BOOLEAN,
  error_message TEXT,
  code_id UUID,
  code_type TEXT,
  amount INT,
  upgrade_tier TEXT,
  max_uses_per_user INT,
  current_user_uses INT,
  total_uses INT,
  max_uses INT
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code_id UUID;
  v_code_type TEXT;
  v_amount INT;
  v_upgrade_tier TEXT;
  v_max_uses_per_user INT;
  v_max_uses INT;
  v_user_uses INT;
  v_total_uses INT;
  v_applicable_tiers TEXT[];
  v_is_active BOOLEAN;
  v_valid_from TIMESTAMPTZ;
  v_valid_until TIMESTAMPTZ;
BEGIN
  IF p_user_id IS NULL THEN
    p_user_id := auth.uid();
  END IF;
  
  IF p_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'Not authenticated'::TEXT, NULL::UUID, NULL::TEXT, NULL::INT, NULL::TEXT, NULL::INT, NULL::INT, NULL::INT, NULL::INT;
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT id, code_type, amount, upgrade_tier, max_uses_per_user, max_uses, applicable_tiers, is_active, valid_from, valid_until
  INTO v_code_id, v_code_type, v_amount, v_upgrade_tier, v_max_uses_per_user, v_max_uses, v_applicable_tiers, v_is_active, v_valid_from, v_valid_until
  FROM public.promo_codes
  WHERE UPPER(code) = p_code;

  IF v_code_id IS NULL THEN
    RETURN QUERY SELECT false, 'Promo code not found'::TEXT, NULL::UUID, NULL::TEXT, NULL::INT, NULL::TEXT, NULL::INT, NULL::INT, NULL::INT, NULL::INT;
    RETURN;
  END IF;

  IF v_is_active = false THEN
    RETURN QUERY SELECT false, 'Promo code is not active'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
    RETURN;
  END IF;

  IF NOW() < v_valid_from THEN
    RETURN QUERY SELECT false, 'Promo code is not yet valid'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
    RETURN;
  END IF;

  IF NOW() > v_valid_until THEN
    RETURN QUERY SELECT false, 'Promo code has expired'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
    RETURN;
  END IF;

  IF p_for_tier IS NOT NULL AND ARRAY_LENGTH(v_applicable_tiers, 1) > 0 THEN
    IF NOT p_for_tier = ANY(v_applicable_tiers) THEN
      RETURN QUERY SELECT false, 'This promo code is not applicable for the ' || p_for_tier || ' tier'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
      RETURN;
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_total_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id;

  IF v_max_uses IS NOT NULL AND v_total_uses >= v_max_uses THEN
    RETURN QUERY SELECT false, 'Promo code has reached its usage limit'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, v_total_uses, v_max_uses;
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_user_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id AND user_id = p_user_id;

  IF v_user_uses >= v_max_uses_per_user THEN
    RETURN QUERY SELECT false, 'You have already used this promo code the maximum number of times'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, v_user_uses, v_total_uses, v_max_uses;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::TEXT, v_code_id, v_code_type, v_amount, v_upgrade_tier, v_max_uses_per_user, v_user_uses, v_total_uses, v_max_uses;
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_promo_code(TEXT, UUID, TEXT) TO authenticated;

-- Function: redeem_promo_code
DROP FUNCTION IF EXISTS public.redeem_promo_code(TEXT, UUID, UUID, INT);
CREATE OR REPLACE FUNCTION public.redeem_promo_code(
  p_code TEXT,
  p_user_id UUID DEFAULT auth.uid(),
  p_subscription_queue_id UUID DEFAULT NULL,
  p_discount_value_cents INT DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, error_message TEXT, usage_id UUID, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_code_id UUID;
  v_user_id UUID;
  v_usage_id UUID;
  v_max_uses_per_user INT;
  v_user_uses INT;
  v_max_uses INT;
  v_total_uses INT;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'Not authenticated'::TEXT, NULL::UUID, 'User not authenticated'::TEXT;
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT id, max_uses_per_user, max_uses
  INTO v_code_id, v_max_uses_per_user, v_max_uses
  FROM public.promo_codes
  WHERE UPPER(code) = p_code AND is_active = true;

  IF v_code_id IS NULL THEN
    RETURN QUERY SELECT false, 'Invalid or inactive promo code'::TEXT, NULL::UUID, 'The promo code could not be found'::TEXT;
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_user_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id AND user_id = v_user_id;

  IF v_user_uses >= v_max_uses_per_user THEN
    RETURN QUERY SELECT false, 'Usage limit exceeded'::TEXT, NULL::UUID, 'You have already used this code the maximum number of times'::TEXT;
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_total_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id;

  IF v_max_uses IS NOT NULL AND v_total_uses >= v_max_uses THEN
    RETURN QUERY SELECT false, 'Code limit reached'::TEXT, NULL::UUID, 'This promo code has reached its usage limit'::TEXT;
    RETURN;
  END IF;

  INSERT INTO public.promo_code_usages (promo_code_id, user_id, subscription_queue_id, discount_value_cents, applied_tier)
  VALUES (v_code_id, v_user_id, p_subscription_queue_id, p_discount_value_cents, (SELECT subscription_tier FROM public.users WHERE id = v_user_id))
  RETURNING id INTO v_usage_id;

  RETURN QUERY SELECT true, NULL::TEXT, v_usage_id, 'Promo code redeemed successfully'::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) TO authenticated;

-- Function: get_promo_code_details
DROP FUNCTION IF EXISTS public.get_promo_code_details(TEXT);
CREATE OR REPLACE FUNCTION public.get_promo_code_details(p_code TEXT)
RETURNS TABLE (code TEXT, description TEXT, code_type TEXT, amount INT, upgrade_tier TEXT, campaign_name TEXT, valid_until TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT pc.code, pc.description, pc.code_type, pc.amount, pc.upgrade_tier, pc.campaign_name, pc.valid_until
  FROM public.promo_codes pc
  WHERE UPPER(pc.code) = UPPER(TRIM(p_code)) AND pc.is_active = true AND pc.valid_until > now() AND pc.valid_from <= now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_promo_code_details(TEXT) TO authenticated;

-- Admin Function: create_promo_code
DROP FUNCTION IF EXISTS public.admin_create_promo_code;
CREATE OR REPLACE FUNCTION public.admin_create_promo_code(
  p_code TEXT,
  p_description TEXT,
  p_code_type TEXT,
  p_amount INT DEFAULT NULL,
  p_upgrade_tier TEXT DEFAULT NULL,
  p_applicable_tiers TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_campaign_name TEXT DEFAULT NULL,
  p_max_uses INT DEFAULT NULL,
  p_max_uses_per_user INT DEFAULT 1,
  p_valid_from TIMESTAMPTZ DEFAULT now(),
  p_valid_until TIMESTAMPTZ DEFAULT (now() + INTERVAL '90 days'),
  p_min_tier TEXT DEFAULT NULL
)
RETURNS TABLE (id UUID, code TEXT, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
  v_code_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id AND is_admin = true) THEN
    RAISE EXCEPTION 'Only admins can create promo codes';
  END IF;

  IF p_code IS NULL OR TRIM(p_code) = '' THEN
    RAISE EXCEPTION 'Code is required';
  END IF;

  IF p_code_type NOT IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade') THEN
    RAISE EXCEPTION 'Invalid code type';
  END IF;

  INSERT INTO public.promo_codes (code, description, code_type, amount, upgrade_tier, applicable_tiers, min_tier, campaign_name, max_uses, max_uses_per_user, valid_from, valid_until, created_by, is_active)
  VALUES (UPPER(TRIM(p_code)), p_description, p_code_type, p_amount, p_upgrade_tier, p_applicable_tiers, p_min_tier, p_campaign_name, p_max_uses, p_max_uses_per_user, p_valid_from, p_valid_until, v_user_id, true)
  RETURNING public.promo_codes.id INTO v_code_id;

  RETURN QUERY SELECT v_code_id, UPPER(TRIM(p_code)), now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_promo_code TO authenticated;

-- Admin Function: update_promo_code
DROP FUNCTION IF EXISTS public.admin_update_promo_code;
CREATE OR REPLACE FUNCTION public.admin_update_promo_code(
  p_id UUID,
  p_is_active BOOLEAN DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL,
  p_valid_from TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_code_type TEXT DEFAULT NULL,
  p_amount INT DEFAULT NULL,
  p_upgrade_tier TEXT DEFAULT NULL,
  p_max_uses_per_user INT DEFAULT NULL,
  p_applicable_tiers TEXT[] DEFAULT NULL
)
RETURNS TABLE (id UUID, code TEXT, is_active BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id AND is_admin = true) THEN
    RAISE EXCEPTION 'Only admins can update promo codes';
  END IF;

  IF p_code_type IS NOT NULL AND p_code_type NOT IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade') THEN
    RAISE EXCEPTION 'Invalid code type';
  END IF;

  UPDATE public.promo_codes SET
    is_active = COALESCE(p_is_active, is_active),
    valid_until = COALESCE(p_valid_until, valid_until),
    valid_from = COALESCE(p_valid_from, valid_from),
    max_uses = COALESCE(p_max_uses, max_uses),
    description = COALESCE(p_description, description),
    code_type = COALESCE(p_code_type, code_type),
    amount = COALESCE(p_amount, amount),
    upgrade_tier = COALESCE(p_upgrade_tier, upgrade_tier),
    max_uses_per_user = COALESCE(p_max_uses_per_user, max_uses_per_user),
    applicable_tiers = COALESCE(p_applicable_tiers, applicable_tiers),
    updated_at = now()
  WHERE id = p_id;

  RETURN QUERY SELECT id, code, is_active FROM public.promo_codes WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_promo_code TO authenticated;

-- Admin Function: get_promo_usage_stats
DROP FUNCTION IF EXISTS public.admin_get_promo_usage_stats(UUID);
CREATE OR REPLACE FUNCTION public.admin_get_promo_usage_stats(p_promo_code_id UUID)
RETURNS TABLE (code TEXT, total_uses INT, unique_users INT, total_discount_cents BIGINT, created_at TIMESTAMPTZ, valid_until TIMESTAMPTZ, is_active BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id AND is_admin = true) THEN
    RAISE EXCEPTION 'Only admins can view promo stats';
  END IF;

  RETURN QUERY
  SELECT pc.code, COUNT(pcu.id)::INT as total_uses, COUNT(DISTINCT pcu.user_id)::INT as unique_users,
         COALESCE(SUM(pcu.discount_value_cents), 0)::BIGINT as total_discount_cents,
         pc.created_at, pc.valid_until, pc.is_active
  FROM public.promo_codes pc
  LEFT JOIN public.promo_code_usages pcu ON pcu.promo_code_id = pc.id
  WHERE pc.id = p_promo_code_id
  GROUP BY pc.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_stats(UUID) TO authenticated;

COMMIT;

COMMENT ON FUNCTION public.validate_promo_code IS 'Validates a promo code without redeeming it';
COMMENT ON FUNCTION public.redeem_promo_code IS 'Records a promo code redemption';
COMMENT ON FUNCTION public.get_promo_code_details IS 'Returns details about a specific promo code';
COMMENT ON FUNCTION public.admin_create_promo_code IS 'Creates a new promo code (admin only)';
COMMENT ON FUNCTION public.admin_update_promo_code IS 'Updates an existing promo code (admin only)';
COMMENT ON FUNCTION public.admin_get_promo_usage_stats IS 'Gets usage statistics for a promo code (admin only)';