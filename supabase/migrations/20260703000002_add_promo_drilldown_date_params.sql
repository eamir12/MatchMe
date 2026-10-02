-- Add date range parameters to promo drill-down RPCs
-- so they respect the analytics date filter chosen by the admin.

DROP FUNCTION IF EXISTS admin_get_promo_usage_by_user(TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS admin_get_promo_usage_by_user();
DROP FUNCTION IF EXISTS admin_get_promo_usage_by_code(TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS admin_get_promo_usage_by_code();
DROP FUNCTION IF EXISTS admin_get_promo_discount_by_date(TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS admin_get_promo_discount_by_date();

CREATE OR REPLACE FUNCTION admin_get_promo_usage_by_user(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
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
  WHERE (p_start_date IS NULL OR pcu.redeemed_at >= p_start_date)
    AND (p_end_date IS NULL OR pcu.redeemed_at <= p_end_date)
  GROUP BY pcu.user_id, u.name, u.email
  ORDER BY total_uses DESC, total_discount_cents DESC;
END;
$$;

CREATE OR REPLACE FUNCTION admin_get_promo_usage_by_code(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
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
  WHERE (p_start_date IS NULL OR pcu.redeemed_at >= p_start_date)
    AND (p_end_date IS NULL OR pcu.redeemed_at <= p_end_date)
  GROUP BY pc.id, pc.code, pc.code_type, pc.amount, pc.is_active, pc.valid_until
  HAVING COUNT(pcu.id) > 0
  ORDER BY total_uses DESC, total_discount_cents DESC;
END;
$$;

CREATE OR REPLACE FUNCTION admin_get_promo_discount_by_date(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
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
  WHERE (p_start_date IS NULL OR pcu.redeemed_at >= p_start_date)
    AND (p_end_date IS NULL OR pcu.redeemed_at <= p_end_date)
  GROUP BY TO_CHAR(pcu.redeemed_at, 'YYYY-MM-DD')
  ORDER BY date DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_promo_usage_by_user TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_usage_by_user(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_usage_by_code TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_usage_by_code(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_discount_by_date TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promo_discount_by_date(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
