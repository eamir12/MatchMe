-- ============================================================================
-- Update Admin Policies to Use Function
-- ============================================================================
-- This updates the existing admin policies to use the is_admin_user() function
-- instead of inline subqueries to avoid circular dependency issues.
-- Also adds missing policies for app_config table.
-- ============================================================================

BEGIN;

-- Add app_config policy (was missing)
DROP POLICY IF EXISTS "Admins can read app_config" ON public.app_config;
CREATE POLICY "Admins can read app_config" ON public.app_config
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update app_config" ON public.app_config;
CREATE POLICY "Admins can update app_config" ON public.app_config
FOR UPDATE
USING (public.is_admin_user());

-- Update users policy
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
USING (public.is_admin_user());

-- Update intents policy
DROP POLICY IF EXISTS "Admins can read intents" ON public.intents;
CREATE POLICY "Admins can read intents" ON public.intents
FOR SELECT
USING (public.is_admin_user());

-- Update interests policy
DROP POLICY IF EXISTS "Admins can read interests" ON public.interests;
CREATE POLICY "Admins can read interests" ON public.interests
FOR SELECT
USING (public.is_admin_user());

-- Update translations policies
DROP POLICY IF EXISTS "Admins can read translations" ON public.translations;
CREATE POLICY "Admins can read translations" ON public.translations
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update translations" ON public.translations;
CREATE POLICY "Admins can update translations" ON public.translations
FOR UPDATE
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert translations" ON public.translations;
CREATE POLICY "Admins can insert translations" ON public.translations
FOR INSERT
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete translations" ON public.translations;
CREATE POLICY "Admins can delete translations" ON public.translations
FOR DELETE
USING (public.is_admin_user());

-- Update subscription_tiers policies
DROP POLICY IF EXISTS "Admins can read subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can read subscription_tiers" ON public.subscription_tiers
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can insert subscription_tiers" ON public.subscription_tiers
FOR INSERT
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can update subscription_tiers" ON public.subscription_tiers
FOR UPDATE
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can delete subscription_tiers" ON public.subscription_tiers
FOR DELETE
USING (public.is_admin_user());

-- Update subscription_plans policies
DROP POLICY IF EXISTS "Admins can read subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can read subscription_plans" ON public.subscription_plans
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can insert subscription_plans" ON public.subscription_plans
FOR INSERT
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can update subscription_plans" ON public.subscription_plans
FOR UPDATE
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can delete subscription_plans" ON public.subscription_plans
FOR DELETE
USING (public.is_admin_user());

-- Update profile_edit_requests policies
DROP POLICY IF EXISTS "Admins can read profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can read profile_edit_requests" ON public.profile_edit_requests
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can update profile_edit_requests" ON public.profile_edit_requests
FOR UPDATE
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can delete profile_edit_requests" ON public.profile_edit_requests
FOR DELETE
USING (public.is_admin_user());

-- Add admin_broadcasts policies (for broadcast management)
DROP POLICY IF EXISTS "Admins can read admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can read admin_broadcasts" ON public.admin_broadcasts
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can insert admin_broadcasts" ON public.admin_broadcasts
FOR INSERT
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can update admin_broadcasts" ON public.admin_broadcasts
FOR UPDATE
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can delete admin_broadcasts" ON public.admin_broadcasts
FOR DELETE
USING (public.is_admin_user());

-- Add promo_codes policies (for promo code management)
DROP POLICY IF EXISTS "Admins can read promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can read promo_codes" ON public.promo_codes
FOR SELECT
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can insert promo_codes" ON public.promo_codes
FOR INSERT
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can update promo_codes" ON public.promo_codes
FOR UPDATE
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can delete promo_codes" ON public.promo_codes
FOR DELETE
USING (public.is_admin_user());

COMMIT;