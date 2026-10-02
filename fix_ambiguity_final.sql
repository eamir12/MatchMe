-- FINAL FIX: Completely rewritten functions with zero ambiguity
-- Drop old functions
DROP FUNCTION IF EXISTS public.admin_create_promo_code(
  TEXT, TEXT, TEXT, INT, INT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT
);

DROP FUNCTION IF EXISTS public.redeem_promo_code(TEXT, UUID, UUID, INT);

DROP FUNCTION IF EXISTS public.admin_update_promo_code(UUID, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT);

-- RECREATE: admin_create_promo_code
CREATE FUNCTION public.admin_create_promo_code(
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
  result_id UUID,
  result_code TEXT,
  result_created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
  v_code_id UUID;
  v_creation_time TIMESTAMPTZ;
BEGIN
  -- Verify authentication
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Verify admin status
  IF NOT EXISTS (
    SELECT 1 FROM public.users 
    WHERE public.users.id = v_user_id 
    AND public.users.is_admin = true
  ) THEN
    RAISE EXCEPTION 'Only admins can create promo codes';
  END IF;

  -- Validate code
  IF TRIM(COALESCE(p_code, '')) = '' THEN
    RAISE EXCEPTION 'Code is required';
  END IF;

  -- Validate type
  IF p_code_type NOT IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade') THEN
    RAISE EXCEPTION 'Invalid code type';
  END IF;

  -- Store current time
  v_creation_time := now();

  -- Insert promo code using explicit INSERT
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
    is_active,
    created_at
  ) VALUES (
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
    true,
    v_creation_time
  );

  -- Use LAST_INSERT_ID equivalent in PostgreSQL
  SELECT gen_random_uuid() INTO v_code_id;
  
  -- Query back to get the actual inserted ID
  SELECT row.id INTO v_code_id 
  FROM public.promo_codes row 
  WHERE row.code = UPPER(TRIM(p_code))
  ORDER BY row.created_at DESC 
  LIMIT 1;

  -- Return results with renamed columns to avoid ambiguity
  RETURN QUERY SELECT v_code_id, UPPER(TRIM(p_code)), v_creation_time;
  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_promo_code(
  TEXT, TEXT, TEXT, INT, INT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) TO authenticated;

-- RECREATE: redeem_promo_code  
CREATE FUNCTION public.redeem_promo_code(
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
  v_usage_id UUID;
  v_max_uses_per_user INT;
  v_current_uses INT;
  v_max_uses INT;
  v_current_global_uses INT;
BEGIN
  -- Get authenticated user
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'Not authenticated'::TEXT, NULL::UUID, 'User not authenticated'::TEXT;
    RETURN;
  END IF;

  -- Find promo code
  SELECT code_pc.id, code_pc.max_uses_per_user, code_pc.max_uses
  INTO v_code_id, v_max_uses_per_user, v_max_uses
  FROM public.promo_codes code_pc
  WHERE UPPER(code_pc.code) = UPPER(p_code)
    AND code_pc.is_active = true
    AND code_pc.valid_until > now();

  IF v_code_id IS NULL THEN
    RETURN QUERY SELECT false, 'Invalid code'::TEXT, NULL::UUID, 'Code not found or expired'::TEXT;
    RETURN;
  END IF;

  -- Check global usage limit
  IF v_max_uses IS NOT NULL THEN
    SELECT COUNT(*) INTO v_current_global_uses
    FROM public.promo_code_usages usage_pcu
    WHERE usage_pcu.promo_code_id = v_code_id;

    IF v_current_global_uses >= v_max_uses THEN
      RETURN QUERY SELECT false, 'Code limit reached'::TEXT, NULL::UUID, 'This code is no longer available'::TEXT;
      RETURN;
    END IF;
  END IF;

  -- Check per-user usage limit
  SELECT COUNT(*) INTO v_current_uses
  FROM public.promo_code_usages usage_pcu
  WHERE usage_pcu.promo_code_id = v_code_id 
    AND usage_pcu.user_id = v_user_id;

  IF v_current_uses >= v_max_uses_per_user THEN
    RETURN QUERY SELECT false, 'Already used'::TEXT, NULL::UUID, 'You have already used this code'::TEXT;
    RETURN;
  END IF;

  -- Record usage
  INSERT INTO public.promo_code_usages (
    promo_code_id,
    user_id,
    subscription_queue_id,
    discount_value_cents,
    redeemed_at
  ) VALUES (
    v_code_id,
    v_user_id,
    p_subscription_queue_id,
    p_discount_value_cents,
    now()
  );

  -- Get the inserted usage ID
  SELECT usage_row.id INTO v_usage_id
  FROM public.promo_code_usages usage_row
  WHERE usage_row.user_id = v_user_id
    AND usage_row.promo_code_id = v_code_id
  ORDER BY usage_row.redeemed_at DESC
  LIMIT 1;

  RETURN QUERY SELECT true, ''::TEXT, v_usage_id, 'Code redeemed successfully'::TEXT;
  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) TO authenticated;

-- RECREATE: admin_update_promo_code
CREATE FUNCTION public.admin_update_promo_code(
  p_code_id UUID,
  p_is_active BOOLEAN DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL,
  p_valid_from TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT NULL
)
RETURNS TABLE (
  result_id UUID,
  result_code TEXT,
  result_is_active BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Verify admin status
  v_user_id := auth.uid();
  IF NOT EXISTS (
    SELECT 1 FROM public.users admin_user
    WHERE admin_user.id = v_user_id 
    AND admin_user.is_admin = true
  ) THEN
    RAISE EXCEPTION 'Only admins can update promo codes';
  END IF;

  -- Update promo code
  UPDATE public.promo_codes target
  SET
    is_active = COALESCE(p_is_active, target.is_active),
    valid_until = COALESCE(p_valid_until, target.valid_until),
    valid_from = COALESCE(p_valid_from, target.valid_from),
    max_uses = COALESCE(p_max_uses, target.max_uses),
    updated_at = now()
  WHERE target.id = p_code_id;

  -- Return updated record
  RETURN QUERY 
  SELECT ret.id, ret.code, ret.is_active
  FROM public.promo_codes ret
  WHERE ret.id = p_code_id;

  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_promo_code(UUID, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT) TO authenticated;
