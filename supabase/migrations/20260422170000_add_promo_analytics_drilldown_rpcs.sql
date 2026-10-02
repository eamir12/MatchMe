-- RPC functions for promo code analytics drill-down

-- Drop existing functions to allow signature changes
DROP FUNCTION IF EXISTS admin_get_promo_usage_by_user();
DROP FUNCTION IF EXISTS admin_get_promo_usage_user_details(UUID);
DROP FUNCTION IF EXISTS admin_get_promo_usage_by_code();
DROP FUNCTION IF EXISTS admin_get_promo_discount_by_date();

-- Get promo usage stats per user (for Unique Users drill-down)
CREATE OR REPLACE FUNCTION admin_get_promo_usage_by_user()
RETURNS TABLE (
  user_id UUID,
  user_name TEXT,
  total_uses INT,
  total_discount_cents BIGINT,
  first_use TIMESTAMPTZ,
  last_use TIMESTAMPTZ,
  unique_promos INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if user is admin
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Permission denied: user is not an admin';
  END IF;

  RETURN QUERY
  SELECT
    pcu.user_id,
    COALESCE(NULLIF(BTRIM(u.name), ''), u.email) AS user_name,
    COUNT(pcu.id)::INT AS total_uses,
    COALESCE(SUM(pcu.discount_value_cents), 0)::BIGINT AS total_discount_cents,
    MIN(pcu.redeemed_at) AS first_use,
    MAX(pcu.redeemed_at) AS last_use,
    COUNT(DISTINCT pcu.promo_code_id)::INT AS unique_promos
  FROM public.promo_code_usages AS pcu
  INNER JOIN public.users AS u ON u.id = pcu.user_id
  GROUP BY pcu.user_id, u.name, u.email
  ORDER BY total_uses DESC, total_discount_cents DESC;
END;
$$;

-- Get detailed promo usage history for a specific user
CREATE OR REPLACE FUNCTION admin_get_promo_usage_user_details(p_user_id UUID)
RETURNS TABLE (
  promo_code_id UUID,
  promo_code TEXT,
  code_type TEXT,
  amount INT,
  redeemed_at TIMESTAMPTZ,
  discount_value_cents INT,
  applied_tier TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if user is admin
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Permission denied: user is not an admin';
  END IF;

  RETURN QUERY
  SELECT
    pc.id AS promo_code_id,
    pc.code AS promo_code,
    pc.code_type,
    pc.amount,
    pcu.redeemed_at,
    pcu.discount_value_cents,
    pcu.applied_tier
  FROM public.promo_code_usages AS pcu
  INNER JOIN public.promo_codes AS pc ON pc.id = pcu.promo_code_id
  WHERE pcu.user_id = p_user_id
  ORDER BY pcu.redeemed_at DESC;
END;
$$;

-- Get promo usage stats per promo code (for Total Uses drill-down)
CREATE OR REPLACE FUNCTION admin_get_promo_usage_by_code()
RETURNS TABLE (
  promo_code_id UUID,
  promo_code TEXT,
  code_type TEXT,
  amount INT,
  total_uses INT,
  unique_users INT,
  total_discount_cents BIGINT,
  is_active BOOLEAN,
  valid_until TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if user is admin
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Permission denied: user is not an admin';
  END IF;

  RETURN QUERY
  SELECT
    pc.id AS promo_code_id,
    pc.code AS promo_code,
    pc.code_type,
    pc.amount,
    COUNT(pcu.id)::INT AS total_uses,
    COUNT(DISTINCT pcu.user_id)::INT AS unique_users,
    COALESCE(SUM(pcu.discount_value_cents), 0)::BIGINT AS total_discount_cents,
    pc.is_active,
    pc.valid_until
  FROM public.promo_codes AS pc
  INNER JOIN public.promo_code_usages AS pcu ON pcu.promo_code_id = pc.id
  GROUP BY pc.id, pc.code, pc.code_type, pc.amount, pc.is_active, pc.valid_until
  HAVING COUNT(pcu.id) > 0
  ORDER BY total_uses DESC, total_discount_cents DESC;
END;
$$;

-- Get discount breakdown over time (for Total Discount drill-down)
CREATE OR REPLACE FUNCTION admin_get_promo_discount_by_date()
RETURNS TABLE (
  date TEXT,
  total_discount_cents BIGINT,
  total_uses INT,
  unique_users INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Check if user is admin
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Permission denied: user is not an admin';
  END IF;

  RETURN QUERY
  SELECT
    TO_CHAR(pcu.redeemed_at, 'YYYY-MM-DD') AS date,
    COALESCE(SUM(pcu.discount_value_cents), 0)::BIGINT AS total_discount_cents,
    COUNT(pcu.id)::INT AS total_uses,
    COUNT(DISTINCT pcu.user_id)::INT AS unique_users
  FROM public.promo_code_usages AS pcu
  WHERE pcu.redeemed_at >= NOW() - INTERVAL '90 days'
  GROUP BY TO_CHAR(pcu.redeemed_at, 'YYYY-MM-DD')
  ORDER BY date DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_promo_usage_by_user TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_usage_user_details TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_usage_by_code TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_discount_by_date TO authenticated;
