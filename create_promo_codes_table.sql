-- Drop and recreate Promo Codes table with simplified schema
-- Uses single 'amount' column for all code types:
--   - discount_percentage: amount = 20 (means 20%)
--   - discount_fixed: amount = 500 (means $5.00 in cents)
--   - free_days: amount = 7 (means 7 days)
--   - tier_upgrade: amount not used

BEGIN;

-- Drop existing tables (will lose data - backup first if needed)
DROP TABLE IF EXISTS public.promo_code_usages CASCADE;
DROP TABLE IF EXISTS public.promo_codes CASCADE;

-- Table: promo_codes
-- Stores the definition and configuration of promo codes
CREATE TABLE public.promo_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  description TEXT,
  
  -- Code Type: 'discount_percentage', 'discount_fixed', 'free_days', 'tier_upgrade'
  code_type TEXT NOT NULL,
  
  -- Amount: interpretation depends on code_type
  -- discount_percentage: percentage (0-100)
  -- discount_fixed: amount in cents
  -- free_days: number of days
  -- tier_upgrade: not used
  amount INT DEFAULT NULL,
  
  -- Upgrade target for tier_upgrade type
  upgrade_tier TEXT DEFAULT NULL,
  
  -- Applicability Constraints
  applicable_tiers TEXT[] DEFAULT ARRAY[]::TEXT[],
  min_tier TEXT DEFAULT NULL,
  
  -- Usage Limits
  max_uses INT DEFAULT NULL,
  max_uses_per_user INT DEFAULT 1,
  
  -- Temporal Constraints
  valid_from TIMESTAMPTZ DEFAULT now(),
  valid_until TIMESTAMPTZ DEFAULT (now() + INTERVAL '90 days'),
  
  -- Status
  is_active BOOLEAN DEFAULT true,
  
  -- Metadata
  campaign_name TEXT,
  created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table: promo_code_usages
-- Tracks individual redemptions of promo codes
CREATE TABLE public.promo_code_usages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_code_id UUID NOT NULL REFERENCES public.promo_codes(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  subscription_queue_id UUID REFERENCES public.user_subscription_queue(id) ON DELETE SET NULL,
  redeemed_at TIMESTAMPTZ DEFAULT now(),
  discount_value_cents INT,
  applied_tier TEXT,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes
CREATE INDEX idx_promo_codes_code ON public.promo_codes(code);
CREATE INDEX idx_promo_codes_active ON public.promo_codes(is_active, valid_until);
CREATE INDEX idx_promo_codes_campaign ON public.promo_codes(campaign_name);
CREATE INDEX idx_promo_usages_user_promo ON public.promo_code_usages(user_id, promo_code_id);
CREATE INDEX idx_promo_usages_promo ON public.promo_code_usages(promo_code_id);
CREATE INDEX idx_promo_usages_user ON public.promo_code_usages(user_id);
CREATE INDEX idx_promo_usages_redeemed_at ON public.promo_code_usages(redeemed_at);

-- RLS
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promo_code_usages ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DROP POLICY IF EXISTS "Allow public read active promo codes" ON public.promo_codes;
CREATE POLICY "Allow public read active promo codes"
  ON public.promo_codes FOR SELECT
  USING (is_active = true AND valid_until > now());

DROP POLICY IF EXISTS "Allow admins create promo codes" ON public.promo_codes;
CREATE POLICY "Allow admins create promo codes"
  ON public.promo_codes FOR INSERT
  WITH CHECK (auth.uid() IN (SELECT id FROM public.users WHERE is_admin = true));

DROP POLICY IF EXISTS "Allow admins update promo codes" ON public.promo_codes;
CREATE POLICY "Allow admins update promo codes"
  ON public.promo_codes FOR UPDATE
  USING (auth.uid() IN (SELECT id FROM public.users WHERE is_admin = true));

DROP POLICY IF EXISTS "Allow admins delete promo codes" ON public.promo_codes;
CREATE POLICY "Allow admins delete promo codes"
  ON public.promo_codes FOR DELETE
  USING (auth.uid() IN (SELECT id FROM public.users WHERE is_admin = true));

DROP POLICY IF EXISTS "Users can view their own usage" ON public.promo_code_usages;
CREATE POLICY "Users can view their own usage"
  ON public.promo_code_usages FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can view all usages" ON public.promo_code_usages;
CREATE POLICY "Admins can view all usages"
  ON public.promo_code_usages FOR SELECT
  USING (auth.uid() IN (SELECT id FROM public.users WHERE is_admin = true));

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_promo_codes_updated_at ON public.promo_codes;
CREATE TRIGGER update_promo_codes_updated_at
  BEFORE UPDATE ON public.promo_codes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- Permissions
GRANT SELECT ON public.promo_codes TO authenticated;
GRANT SELECT ON public.promo_code_usages TO authenticated;

COMMIT;

COMMENT ON TABLE public.promo_codes IS 'Stores promotional code configurations';
COMMENT ON TABLE public.promo_code_usages IS 'Tracks redemptions of promo codes';