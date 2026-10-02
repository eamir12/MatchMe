-- Fix validate_promo_code failing with:
-- column reference "code_type" is ambiguous.
--
-- In PL/pgSQL, RETURNS TABLE columns are variables in the function scope.
-- The output column named code_type can collide with promo_codes.code_type
-- unless every table column reference is qualified.

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
  v_user_uses INT := 0;
  v_total_uses INT := 0;
  v_applicable_tiers TEXT[];
  v_is_active BOOLEAN;
  v_valid_from TIMESTAMPTZ;
  v_valid_until TIMESTAMPTZ;
BEGIN
  p_user_id := COALESCE(p_user_id, auth.uid());

  IF p_user_id IS NULL THEN
    RETURN QUERY
    SELECT false, 'Not authenticated'::TEXT, NULL::UUID, NULL::TEXT, NULL::INT, NULL::TEXT, NULL::INT, NULL::INT, NULL::INT, NULL::INT;
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT
    pc.id,
    pc.code_type,
    pc.amount,
    pc.upgrade_tier,
    pc.max_uses_per_user,
    pc.max_uses,
    pc.applicable_tiers,
    pc.is_active,
    pc.valid_from,
    pc.valid_until
  INTO
    v_code_id,
    v_code_type,
    v_amount,
    v_upgrade_tier,
    v_max_uses_per_user,
    v_max_uses,
    v_applicable_tiers,
    v_is_active,
    v_valid_from,
    v_valid_until
  FROM public.promo_codes AS pc
  WHERE UPPER(pc.code) = p_code;

  IF v_code_id IS NULL THEN
    RETURN QUERY
    SELECT false, 'Promo code not found'::TEXT, NULL::UUID, NULL::TEXT, NULL::INT, NULL::TEXT, NULL::INT, NULL::INT, NULL::INT, NULL::INT;
    RETURN;
  END IF;

  IF v_is_active = false THEN
    RETURN QUERY
    SELECT false, 'Promo code is not active'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
    RETURN;
  END IF;

  IF now() < v_valid_from THEN
    RETURN QUERY
    SELECT false, 'Promo code is not yet valid'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
    RETURN;
  END IF;

  IF now() > v_valid_until THEN
    RETURN QUERY
    SELECT false, 'Promo code has expired'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
    RETURN;
  END IF;

  IF p_for_tier IS NOT NULL AND ARRAY_LENGTH(v_applicable_tiers, 1) > 0 THEN
    IF NOT p_for_tier = ANY(v_applicable_tiers) THEN
      RETURN QUERY
      SELECT false, 'This promo code is not applicable for the ' || p_for_tier || ' tier'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, 0::INT, v_max_uses;
      RETURN;
    END IF;
  END IF;

  SELECT COUNT(*)::INT
  INTO v_total_uses
  FROM public.promo_code_usages AS pcu
  WHERE pcu.promo_code_id = v_code_id;

  IF v_max_uses IS NOT NULL AND v_total_uses >= v_max_uses THEN
    RETURN QUERY
    SELECT false, 'Promo code has reached its usage limit'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, 0::INT, v_total_uses, v_max_uses;
    RETURN;
  END IF;

  SELECT COUNT(*)::INT
  INTO v_user_uses
  FROM public.promo_code_usages AS pcu
  WHERE pcu.promo_code_id = v_code_id
    AND pcu.user_id = p_user_id;

  IF v_user_uses >= v_max_uses_per_user THEN
    RETURN QUERY
    SELECT false, 'You have already used this promo code the maximum number of times'::TEXT, v_code_id, NULL::TEXT, NULL::INT, NULL::TEXT, v_max_uses_per_user, v_user_uses, v_total_uses, v_max_uses;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT true, NULL::TEXT, v_code_id, v_code_type, v_amount, v_upgrade_tier, v_max_uses_per_user, v_user_uses, v_total_uses, v_max_uses;
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_promo_code(TEXT, UUID, TEXT) TO authenticated;
