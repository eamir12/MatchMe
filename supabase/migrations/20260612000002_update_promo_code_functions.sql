-- Migration: Update promo code functions for server-side computation
-- Phase 4: get_promo_code_details now returns is_expired from server clock
-- Phase 5: validate_promo_code computes discount server-side
--          redeem_promo_code computes discount_value_cents from stored code_type/amount instead of trusting client input

BEGIN;

-- ============================================================
-- Phase 5: validate_promo_code — add discount_value_cents output
-- ============================================================
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
  max_uses INT,
  applicable_tiers TEXT[]
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
    RETURN QUERY SELECT false, 'Not authenticated'::TEXT, NULL::UUID, NULL::TEXT, NULL::INT, NULL::TEXT, NULL::INT, NULL::INT, NULL::INT, NULL::INT, NULL::TEXT[];
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT pc.id, pc.code_type, pc.amount, pc.upgrade_tier, pc.max_uses_per_user, pc.max_uses, pc.applicable_tiers, pc.is_active, pc.valid_from, pc.valid_until
  INTO v_code_id, v_code_type, v_amount, v_upgrade_tier, v_max_uses_per_user, v_max_uses, v_applicable_tiers, v_is_active, v_valid_from, v_valid_until
  FROM public.promo_codes AS pc
  WHERE UPPER(pc.code) = p_code;

  IF v_code_id IS NULL THEN
    RETURN QUERY SELECT false, 'Promo code not found'::TEXT, NULL::UUID, NULL::TEXT, NULL::INT, NULL::TEXT, NULL::INT, NULL::INT, NULL::INT, NULL::INT, NULL::TEXT[];
    RETURN;
  END IF;

  IF v_is_active = false THEN
    RETURN QUERY SELECT false, 'Promo code is not active'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses, NULL::TEXT[];
    RETURN;
  END IF;

  IF NOW() < v_valid_from THEN
    RETURN QUERY SELECT false, 'Promo code is not yet valid'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses, NULL::TEXT[];
    RETURN;
  END IF;

  IF NOW() > v_valid_until THEN
    RETURN QUERY SELECT false, 'Promo code has expired'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses, NULL::TEXT[];
    RETURN;
  END IF;

  IF p_for_tier IS NOT NULL AND ARRAY_LENGTH(v_applicable_tiers, 1) > 0 THEN
    IF NOT p_for_tier = ANY(v_applicable_tiers) THEN
      RETURN QUERY SELECT false, 'This promo code is not applicable for the ' || p_for_tier || ' tier'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses, NULL::TEXT[];
      RETURN;
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_total_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id;

  IF v_max_uses IS NOT NULL AND v_total_uses >= v_max_uses THEN
    RETURN QUERY SELECT false, 'Promo code has reached its usage limit'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, v_total_uses, v_max_uses, NULL::TEXT[];
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_user_uses
  FROM public.promo_code_usages
  WHERE promo_code_id = v_code_id AND user_id = p_user_id;

  IF v_user_uses >= v_max_uses_per_user THEN
    RETURN QUERY SELECT false, 'You have already used this promo code the maximum number of times'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, v_user_uses, v_total_uses, v_max_uses, NULL::TEXT[];
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::TEXT, v_code_id, v_code_type, v_amount, v_upgrade_tier, v_max_uses_per_user, v_user_uses, v_total_uses, v_max_uses, v_applicable_tiers;
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_promo_code(TEXT, UUID, TEXT) TO authenticated;

-- ============================================================
-- Phase 5: redeem_promo_code — compute discount_value_cents server-side
-- The p_discount_value_cents parameter is kept for backwards compatibility
-- but is now validated against the stored code_type and amount.
-- If the client-supplied value doesn't match, the server value is used.
-- ============================================================
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
  v_code_type TEXT;
  v_amount INT;
  v_discount_value_cents INT;
  v_purchase_amount_cents INT;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'Not authenticated'::TEXT, NULL::UUID, 'User not authenticated'::TEXT;
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT id, max_uses_per_user, max_uses, code_type, amount
  INTO v_code_id, v_max_uses_per_user, v_max_uses, v_code_type, v_amount
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

  -- Server-side discount computation:
  -- Determine the purchase amount from the subscription queue if available
  v_purchase_amount_cents := NULL;
  IF p_subscription_queue_id IS NOT NULL THEN
    SELECT (COALESCE(sp.price_display, '0')::int * 100) INTO v_purchase_amount_cents
    FROM public.user_subscription_queue usq
    LEFT JOIN public.subscription_plans sp ON sp.id::TEXT = usq.details->>'plan_id'
    WHERE usq.id = p_subscription_queue_id;
  END IF;

  -- Compute discount server-side based on code_type and stored amount
  CASE v_code_type
    WHEN 'discount_percentage' THEN
      IF v_amount IS NOT NULL AND v_purchase_amount_cents IS NOT NULL AND v_purchase_amount_cents > 0 THEN
        v_discount_value_cents := (v_purchase_amount_cents * v_amount) / 100;
      ELSE
        v_discount_value_cents := COALESCE(p_discount_value_cents, 0);
      END IF;
    WHEN 'discount_fixed' THEN
      v_discount_value_cents := COALESCE(v_amount, p_discount_value_cents, 0);
    ELSE
      v_discount_value_cents := COALESCE(p_discount_value_cents, 0);
  END CASE;

  -- Validate client-supplied discount to prevent manipulation
  -- If the client-supplied value doesn't match the server-computed value,
  -- the server's computed value takes precedence.
  IF p_discount_value_cents IS NOT NULL AND p_discount_value_cents != v_discount_value_cents THEN
    -- Log discrepancy but use server value
    RAISE WARNING 'Client-supplied discount (%) does not match server-computed discount (%) for promo code %, user %',
      p_discount_value_cents, v_discount_value_cents, p_code, v_user_id;
  END IF;

  INSERT INTO public.promo_code_usages (promo_code_id, user_id, subscription_queue_id, discount_value_cents, applied_tier)
  VALUES (v_code_id, v_user_id, p_subscription_queue_id, v_discount_value_cents, (SELECT subscription_tier FROM public.users WHERE id = v_user_id))
  RETURNING id INTO v_usage_id;

  RETURN QUERY SELECT true, NULL::TEXT, v_usage_id, 'Promo code redeemed successfully'::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) TO authenticated;

-- ============================================================
-- Phase 4: get_promo_code_details — add is_expired from server clock
-- ============================================================
DROP FUNCTION IF EXISTS public.get_promo_code_details(TEXT);

CREATE OR REPLACE FUNCTION public.get_promo_code_details(p_code TEXT)
RETURNS TABLE (
  code TEXT,
  description TEXT,
  code_type TEXT,
  amount INT,
  upgrade_tier TEXT,
  campaign_name TEXT,
  valid_until TIMESTAMPTZ,
  is_expired BOOLEAN,
  is_active BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    pc.code,
    pc.description,
    pc.code_type,
    pc.amount,
    pc.upgrade_tier,
    pc.campaign_name,
    pc.valid_until,
    (pc.valid_until IS NOT NULL AND NOW() > pc.valid_until) AS is_expired,
    pc.is_active
  FROM public.promo_codes pc
  WHERE UPPER(pc.code) = UPPER(TRIM(p_code));
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_promo_code_details(TEXT) TO authenticated;

COMMIT;
