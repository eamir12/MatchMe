BEGIN;

CREATE TABLE IF NOT EXISTS public.promo_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL,
  description TEXT,
  code_type TEXT NOT NULL,
  amount INT,
  upgrade_tier TEXT,
  applicable_tiers TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  min_tier TEXT,
  max_uses INT,
  max_uses_per_user INT NOT NULL DEFAULT 1,
  valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '90 days'),
  is_active BOOLEAN NOT NULL DEFAULT true,
  campaign_name TEXT,
  created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.promo_codes
  ADD COLUMN IF NOT EXISTS description TEXT,
  ADD COLUMN IF NOT EXISTS code_type TEXT,
  ADD COLUMN IF NOT EXISTS amount INT,
  ADD COLUMN IF NOT EXISTS upgrade_tier TEXT,
  ADD COLUMN IF NOT EXISTS applicable_tiers TEXT[] DEFAULT ARRAY[]::TEXT[],
  ADD COLUMN IF NOT EXISTS min_tier TEXT,
  ADD COLUMN IF NOT EXISTS max_uses INT,
  ADD COLUMN IF NOT EXISTS max_uses_per_user INT DEFAULT 1,
  ADD COLUMN IF NOT EXISTS valid_from TIMESTAMPTZ DEFAULT now(),
  ADD COLUMN IF NOT EXISTS valid_until TIMESTAMPTZ DEFAULT (now() + INTERVAL '90 days'),
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS campaign_name TEXT,
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

UPDATE public.promo_codes
SET
  applicable_tiers = COALESCE(applicable_tiers, ARRAY[]::TEXT[]),
  max_uses_per_user = COALESCE(max_uses_per_user, 1),
  valid_from = COALESCE(valid_from, created_at, now()),
  valid_until = COALESCE(valid_until, COALESCE(created_at, now()) + INTERVAL '90 days'),
  is_active = COALESCE(is_active, true),
  created_at = COALESCE(created_at, now()),
  updated_at = COALESCE(updated_at, now())
WHERE
  applicable_tiers IS NULL
  OR max_uses_per_user IS NULL
  OR valid_from IS NULL
  OR valid_until IS NULL
  OR is_active IS NULL
  OR created_at IS NULL
  OR updated_at IS NULL;

ALTER TABLE public.promo_codes
  ALTER COLUMN code SET NOT NULL,
  ALTER COLUMN applicable_tiers SET DEFAULT ARRAY[]::TEXT[],
  ALTER COLUMN applicable_tiers SET NOT NULL,
  ALTER COLUMN max_uses_per_user SET DEFAULT 1,
  ALTER COLUMN max_uses_per_user SET NOT NULL,
  ALTER COLUMN valid_from SET DEFAULT now(),
  ALTER COLUMN valid_from SET NOT NULL,
  ALTER COLUMN valid_until SET DEFAULT (now() + INTERVAL '90 days'),
  ALTER COLUMN valid_until SET NOT NULL,
  ALTER COLUMN is_active SET DEFAULT true,
  ALTER COLUMN is_active SET NOT NULL,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL;

CREATE TABLE IF NOT EXISTS public.promo_code_usages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_code_id UUID NOT NULL REFERENCES public.promo_codes(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  subscription_queue_id UUID REFERENCES public.user_subscription_queue(id) ON DELETE SET NULL,
  redeemed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  discount_value_cents INT,
  applied_tier TEXT,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.promo_code_usages
  ADD COLUMN IF NOT EXISTS subscription_queue_id UUID REFERENCES public.user_subscription_queue(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS redeemed_at TIMESTAMPTZ DEFAULT now(),
  ADD COLUMN IF NOT EXISTS discount_value_cents INT,
  ADD COLUMN IF NOT EXISTS applied_tier TEXT,
  ADD COLUMN IF NOT EXISTS ip_address TEXT,
  ADD COLUMN IF NOT EXISTS user_agent TEXT,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();

UPDATE public.promo_code_usages
SET
  redeemed_at = COALESCE(redeemed_at, created_at, now()),
  created_at = COALESCE(created_at, redeemed_at, now())
WHERE redeemed_at IS NULL OR created_at IS NULL;

ALTER TABLE public.promo_code_usages
  ALTER COLUMN redeemed_at SET DEFAULT now(),
  ALTER COLUMN redeemed_at SET NOT NULL,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.promo_codes'::regclass
      AND conname = 'promo_codes_code_key'
  ) THEN
    ALTER TABLE public.promo_codes
      ADD CONSTRAINT promo_codes_code_key UNIQUE (code);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.promo_codes'::regclass
      AND conname = 'promo_codes_code_type_check'
  ) THEN
    ALTER TABLE public.promo_codes
      ADD CONSTRAINT promo_codes_code_type_check
      CHECK (code_type IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.promo_codes'::regclass
      AND conname = 'promo_codes_max_uses_per_user_check'
  ) THEN
    ALTER TABLE public.promo_codes
      ADD CONSTRAINT promo_codes_max_uses_per_user_check
      CHECK (max_uses_per_user >= 1);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.promo_codes'::regclass
      AND conname = 'promo_codes_max_uses_check'
  ) THEN
    ALTER TABLE public.promo_codes
      ADD CONSTRAINT promo_codes_max_uses_check
      CHECK (max_uses IS NULL OR max_uses >= 1);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.promo_codes'::regclass
      AND conname = 'promo_codes_valid_range_check'
  ) THEN
    ALTER TABLE public.promo_codes
      ADD CONSTRAINT promo_codes_valid_range_check
      CHECK (valid_until >= valid_from);
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_promo_codes_code ON public.promo_codes(code);
CREATE INDEX IF NOT EXISTS idx_promo_codes_active ON public.promo_codes(is_active, valid_until);
CREATE INDEX IF NOT EXISTS idx_promo_codes_campaign ON public.promo_codes(campaign_name);
CREATE INDEX IF NOT EXISTS idx_promo_usages_user_promo ON public.promo_code_usages(user_id, promo_code_id);
CREATE INDEX IF NOT EXISTS idx_promo_usages_promo ON public.promo_code_usages(promo_code_id);
CREATE INDEX IF NOT EXISTS idx_promo_usages_user ON public.promo_code_usages(user_id);
CREATE INDEX IF NOT EXISTS idx_promo_usages_redeemed_at ON public.promo_code_usages(redeemed_at);

ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promo_code_usages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow public read active promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow admins create promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow admins update promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow admins delete promo codes" ON public.promo_codes;

CREATE POLICY "Allow public read active promo codes"
  ON public.promo_codes
  FOR SELECT
  USING (
    public.promo_codes.is_active = true
    AND public.promo_codes.valid_from <= now()
    AND public.promo_codes.valid_until > now()
  );

CREATE POLICY "Allow admins create promo codes"
  ON public.promo_codes
  FOR INSERT
  WITH CHECK (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  );

CREATE POLICY "Allow admins update promo codes"
  ON public.promo_codes
  FOR UPDATE
  USING (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  )
  WITH CHECK (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  );

CREATE POLICY "Allow admins delete promo codes"
  ON public.promo_codes
  FOR DELETE
  USING (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  );

DROP POLICY IF EXISTS "Users can view their own usage" ON public.promo_code_usages;
DROP POLICY IF EXISTS "Admins can view all usages" ON public.promo_code_usages;
DROP POLICY IF EXISTS "Admins can insert usages" ON public.promo_code_usages;

CREATE POLICY "Users can view their own usage"
  ON public.promo_code_usages
  FOR SELECT
  USING (auth.uid() = public.promo_code_usages.user_id);

CREATE POLICY "Admins can view all usages"
  ON public.promo_code_usages
  FOR SELECT
  USING (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  );

CREATE POLICY "Admins can insert usages"
  ON public.promo_code_usages
  FOR INSERT
  WITH CHECK (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.promo_codes TO authenticated;
GRANT SELECT ON public.promo_code_usages TO authenticated;

CREATE OR REPLACE FUNCTION public.set_promo_codes_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_promo_codes_updated_at ON public.promo_codes;
CREATE TRIGGER update_promo_codes_updated_at
  BEFORE UPDATE ON public.promo_codes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_promo_codes_updated_at();

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
  v_user_uses INT := 0;
  v_max_uses INT;
  v_total_uses INT := 0;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN QUERY
    SELECT false, 'Not authenticated'::TEXT, NULL::UUID, 'User not authenticated'::TEXT;
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT
    pc.id,
    pc.max_uses_per_user,
    pc.max_uses
  INTO
    v_code_id,
    v_max_uses_per_user,
    v_max_uses
  FROM public.promo_codes AS pc
  WHERE UPPER(pc.code) = p_code
    AND pc.is_active = true;

  IF v_code_id IS NULL THEN
    RETURN QUERY
    SELECT false, 'Invalid or inactive promo code'::TEXT, NULL::UUID, 'The promo code could not be found'::TEXT;
    RETURN;
  END IF;

  SELECT COUNT(*)::INT
  INTO v_user_uses
  FROM public.promo_code_usages AS pcu
  WHERE pcu.promo_code_id = v_code_id
    AND pcu.user_id = v_user_id;

  IF v_user_uses >= v_max_uses_per_user THEN
    RETURN QUERY
    SELECT false, 'Usage limit exceeded'::TEXT, NULL::UUID, 'You have already used this code the maximum number of times'::TEXT;
    RETURN;
  END IF;

  SELECT COUNT(*)::INT
  INTO v_total_uses
  FROM public.promo_code_usages AS pcu
  WHERE pcu.promo_code_id = v_code_id;

  IF v_max_uses IS NOT NULL AND v_total_uses >= v_max_uses THEN
    RETURN QUERY
    SELECT false, 'Code limit reached'::TEXT, NULL::UUID, 'This promo code has reached its usage limit'::TEXT;
    RETURN;
  END IF;

  INSERT INTO public.promo_code_usages (
    promo_code_id,
    user_id,
    subscription_queue_id,
    discount_value_cents,
    applied_tier
  )
  VALUES (
    v_code_id,
    v_user_id,
    p_subscription_queue_id,
    p_discount_value_cents,
    (
      SELECT u.subscription_tier
      FROM public.users AS u
      WHERE u.id = v_user_id
    )
  )
  RETURNING id INTO v_usage_id;

  RETURN QUERY
  SELECT true, NULL::TEXT, v_usage_id, 'Promo code redeemed successfully'::TEXT;
END;
$$;

DROP FUNCTION IF EXISTS public.get_promo_code_details(TEXT);
CREATE OR REPLACE FUNCTION public.get_promo_code_details(p_code TEXT)
RETURNS TABLE (
  code TEXT,
  description TEXT,
  code_type TEXT,
  amount INT,
  upgrade_tier TEXT,
  campaign_name TEXT,
  valid_until TIMESTAMPTZ
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
    pc.valid_until
  FROM public.promo_codes AS pc
  WHERE UPPER(pc.code) = UPPER(TRIM(p_code))
    AND pc.is_active = true
    AND pc.valid_from <= now()
    AND pc.valid_until > now();
END;
$$;

DROP FUNCTION IF EXISTS public.admin_create_promo_code(TEXT, TEXT, TEXT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT);
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = v_user_id
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'Only admins can create promo codes';
  END IF;

  IF p_code IS NULL OR TRIM(p_code) = '' THEN
    RAISE EXCEPTION 'Code is required';
  END IF;

  IF p_code_type NOT IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade') THEN
    RAISE EXCEPTION 'Invalid code type';
  END IF;

  IF p_max_uses_per_user IS NULL OR p_max_uses_per_user < 1 THEN
    RAISE EXCEPTION 'Max uses per user must be at least 1';
  END IF;

  IF p_max_uses IS NOT NULL AND p_max_uses < 1 THEN
    RAISE EXCEPTION 'Max uses must be at least 1 when provided';
  END IF;

  IF p_valid_until < p_valid_from THEN
    RAISE EXCEPTION 'Valid until must be on or after valid from';
  END IF;

  INSERT INTO public.promo_codes (
    code,
    description,
    code_type,
    amount,
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
    NULLIF(TRIM(p_description), ''),
    p_code_type,
    p_amount,
    p_upgrade_tier,
    COALESCE(p_applicable_tiers, ARRAY[]::TEXT[]),
    p_min_tier,
    p_campaign_name,
    p_max_uses,
    p_max_uses_per_user,
    p_valid_from,
    p_valid_until,
    v_user_id,
    true
  )
  RETURNING promo_codes.id INTO v_code_id;

  RETURN QUERY
  SELECT v_code_id, UPPER(TRIM(p_code)), now();
END;
$$;

DROP FUNCTION IF EXISTS public.admin_update_promo_code(UUID, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT, TEXT, TEXT, INT, TEXT, INT, TEXT[]);
DROP FUNCTION IF EXISTS public.admin_update_promo_code(UUID, TEXT, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT, TEXT, TEXT, INT, TEXT, INT, TEXT[], TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_update_promo_code(
  p_id UUID,
  p_code TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL,
  p_valid_from TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_code_type TEXT DEFAULT NULL,
  p_amount INT DEFAULT NULL,
  p_upgrade_tier TEXT DEFAULT NULL,
  p_max_uses_per_user INT DEFAULT NULL,
  p_applicable_tiers TEXT[] DEFAULT NULL,
  p_campaign_name TEXT DEFAULT NULL,
  p_min_tier TEXT DEFAULT NULL
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

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = v_user_id
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'Only admins can update promo codes';
  END IF;

  IF p_code_type IS NOT NULL
     AND p_code_type NOT IN ('discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade') THEN
    RAISE EXCEPTION 'Invalid code type';
  END IF;

  IF p_max_uses_per_user IS NOT NULL AND p_max_uses_per_user < 1 THEN
    RAISE EXCEPTION 'Max uses per user must be at least 1';
  END IF;

  IF p_max_uses IS NOT NULL AND p_max_uses < 1 THEN
    RAISE EXCEPTION 'Max uses must be at least 1 when provided';
  END IF;

  UPDATE public.promo_codes AS pc
  SET
    code = COALESCE(NULLIF(UPPER(TRIM(p_code)), ''), pc.code),
    is_active = COALESCE(p_is_active, pc.is_active),
    valid_until = COALESCE(p_valid_until, pc.valid_until),
    valid_from = COALESCE(p_valid_from, pc.valid_from),
    max_uses = COALESCE(p_max_uses, pc.max_uses),
    description = COALESCE(NULLIF(TRIM(p_description), ''), pc.description),
    code_type = COALESCE(p_code_type, pc.code_type),
    amount = COALESCE(p_amount, pc.amount),
    upgrade_tier = COALESCE(p_upgrade_tier, pc.upgrade_tier),
    max_uses_per_user = COALESCE(p_max_uses_per_user, pc.max_uses_per_user),
    applicable_tiers = COALESCE(p_applicable_tiers, pc.applicable_tiers),
    campaign_name = COALESCE(NULLIF(TRIM(p_campaign_name), ''), pc.campaign_name),
    min_tier = COALESCE(NULLIF(TRIM(p_min_tier), ''), pc.min_tier),
    updated_at = now()
  WHERE pc.id = p_id;

  RETURN QUERY
  SELECT pc.id, pc.code, pc.is_active
  FROM public.promo_codes AS pc
  WHERE pc.id = p_id;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_get_promo_usage_stats(UUID);
CREATE OR REPLACE FUNCTION public.admin_get_promo_usage_stats(p_promo_code_id UUID)
RETURNS TABLE (
  code TEXT,
  total_uses INT,
  unique_users INT,
  total_discount_cents BIGINT,
  created_at TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  is_active BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = v_user_id
      AND u.is_admin = true
  ) THEN
    RAISE EXCEPTION 'Only admins can view promo stats';
  END IF;

  RETURN QUERY
  SELECT
    pc.code,
    COUNT(pcu.id)::INT AS total_uses,
    COUNT(DISTINCT pcu.user_id)::INT AS unique_users,
    COALESCE(SUM(pcu.discount_value_cents), 0)::BIGINT AS total_discount_cents,
    pc.created_at,
    pc.valid_until,
    pc.is_active
  FROM public.promo_codes AS pc
  LEFT JOIN public.promo_code_usages AS pcu
    ON pcu.promo_code_id = pc.id
  WHERE pc.id = p_promo_code_id
  GROUP BY pc.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_promo_code(TEXT, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_promo_code_details(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_promo_code(TEXT, TEXT, TEXT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_promo_code(UUID, TEXT, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT, TEXT, TEXT, INT, TEXT, INT, TEXT[], TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_stats(UUID) TO authenticated;

COMMENT ON TABLE public.promo_codes IS 'Stores promotional code configurations';
COMMENT ON TABLE public.promo_code_usages IS 'Tracks redemptions of promo codes';
COMMENT ON FUNCTION public.validate_promo_code(TEXT, UUID, TEXT) IS 'Validates a promo code without redeeming it';
COMMENT ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) IS 'Records a promo code redemption';
COMMENT ON FUNCTION public.get_promo_code_details(TEXT) IS 'Returns details about a specific promo code';
COMMENT ON FUNCTION public.admin_create_promo_code(TEXT, TEXT, TEXT, INT, TEXT, TEXT[], TEXT, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) IS 'Creates a new promo code (admin only)';
COMMENT ON FUNCTION public.admin_update_promo_code(UUID, TEXT, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, INT, TEXT, TEXT, INT, TEXT, INT, TEXT[], TEXT, TEXT) IS 'Updates an existing promo code (admin only)';
COMMENT ON FUNCTION public.admin_get_promo_usage_stats(UUID) IS 'Gets usage statistics for a promo code (admin only)';

COMMIT;
