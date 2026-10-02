-- Fix ambiguous column reference in RLS policies for promo_codes
-- This migration updates the RLS policies to use fully qualified column names

-- Drop ALL existing policies on both tables
DROP POLICY IF EXISTS "Allow admins full access to promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow admins create promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow admins update promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow admins delete promo codes" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow public read active promo codes" ON public.promo_codes;

DROP POLICY IF EXISTS "Users can view their own usage" ON public.promo_code_usages;
DROP POLICY IF EXISTS "Admins can view all usages" ON public.promo_code_usages;
DROP POLICY IF EXISTS "Admins can insert usages" ON public.promo_code_usages;

-- Create explicit policies for promo_codes with fully qualified column names
CREATE POLICY "Allow public read active promo codes"
  ON public.promo_codes FOR SELECT
  USING (
    public.promo_codes.is_active = true AND public.promo_codes.valid_until > now()
  );

CREATE POLICY "Allow admins create promo codes"
  ON public.promo_codes FOR INSERT
  WITH CHECK (
    auth.uid() IN (SELECT public.users.id FROM public.users WHERE public.users.is_admin = true)
  );

CREATE POLICY "Allow admins update promo codes"
  ON public.promo_codes FOR UPDATE
  USING (
    auth.uid() IN (SELECT public.users.id FROM public.users WHERE public.users.is_admin = true)
  );

CREATE POLICY "Allow admins delete promo codes"
  ON public.promo_codes FOR DELETE
  USING (
    auth.uid() IN (SELECT public.users.id FROM public.users WHERE public.users.is_admin = true)
  );

-- Recreate promo_code_usages policies with fully qualified column names
CREATE POLICY "Users can view their own usage"
  ON public.promo_code_usages FOR SELECT
  USING (auth.uid() = public.promo_code_usages.user_id);

CREATE POLICY "Admins can view all usages"
  ON public.promo_code_usages FOR SELECT
  USING (
    auth.uid() IN (SELECT public.users.id FROM public.users WHERE public.users.is_admin = true)
  );

CREATE POLICY "Admins can insert usages"
  ON public.promo_code_usages FOR INSERT
  WITH CHECK (
    auth.uid() IN (SELECT public.users.id FROM public.users WHERE public.users.is_admin = true)
  );
