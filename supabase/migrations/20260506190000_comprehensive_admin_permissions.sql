-- ============================================================================
-- Comprehensive Admin App Permissions
-- ============================================================================
-- This script grants admin access to all tables needed by the admin app.
-- Run this manually in the Supabase SQL Editor.
-- ============================================================================

-- First, create the is_admin_user function if it doesn't exist
CREATE OR REPLACE FUNCTION public.is_admin_user(user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = user_id
      AND is_admin = true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_admin_user TO authenticated;

-- ============================================================================
-- TABLE POLICIES
-- ============================================================================

-- app_config
ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read app_config" ON public.app_config;
CREATE POLICY "Admins can read app_config" ON public.app_config
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update app_config" ON public.app_config;
CREATE POLICY "Admins can update app_config" ON public.app_config
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert app_config" ON public.app_config;
CREATE POLICY "Admins can insert app_config" ON public.app_config
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

-- subscription_tiers
ALTER TABLE public.subscription_tiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can read subscription_tiers" ON public.subscription_tiers
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can insert subscription_tiers" ON public.subscription_tiers
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can update subscription_tiers" ON public.subscription_tiers
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can delete subscription_tiers" ON public.subscription_tiers
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- subscription_plans
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can read subscription_plans" ON public.subscription_plans
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can insert subscription_plans" ON public.subscription_plans
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can update subscription_plans" ON public.subscription_plans
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can delete subscription_plans" ON public.subscription_plans
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- users
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- intents
ALTER TABLE public.intents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read intents" ON public.intents;
CREATE POLICY "Admins can read intents" ON public.intents
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- interests
ALTER TABLE public.interests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read interests" ON public.interests;
CREATE POLICY "Admins can read interests" ON public.interests
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- translations
ALTER TABLE public.translations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read translations" ON public.translations;
CREATE POLICY "Admins can read translations" ON public.translations
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update translations" ON public.translations;
CREATE POLICY "Admins can update translations" ON public.translations
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert translations" ON public.translations;
CREATE POLICY "Admins can insert translations" ON public.translations
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete translations" ON public.translations;
CREATE POLICY "Admins can delete translations" ON public.translations
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- profile_edit_requests
ALTER TABLE public.profile_edit_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can read profile_edit_requests" ON public.profile_edit_requests
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can update profile_edit_requests" ON public.profile_edit_requests
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can delete profile_edit_requests" ON public.profile_edit_requests
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- admin_broadcasts
ALTER TABLE public.admin_broadcasts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can read admin_broadcasts" ON public.admin_broadcasts
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can insert admin_broadcasts" ON public.admin_broadcasts
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can update admin_broadcasts" ON public.admin_broadcasts
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can delete admin_broadcasts" ON public.admin_broadcasts
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- promo_codes
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can read promo_codes" ON public.promo_codes
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can insert promo_codes" ON public.promo_codes
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can update promo_codes" ON public.promo_codes
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can delete promo_codes" ON public.promo_codes
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- promo_code_usages
ALTER TABLE public.promo_code_usages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read promo_code_usages" ON public.promo_code_usages;
CREATE POLICY "Admins can read promo_code_usages" ON public.promo_code_usages
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ad_campaigns
ALTER TABLE public.ad_campaigns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can read ad_campaigns" ON public.ad_campaigns
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can insert ad_campaigns" ON public.ad_campaigns
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can update ad_campaigns" ON public.ad_campaigns
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can delete ad_campaigns" ON public.ad_campaigns
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- ad_creatives
ALTER TABLE public.ad_creatives ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can read ad_creatives" ON public.ad_creatives
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can insert ad_creatives" ON public.ad_creatives
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can update ad_creatives" ON public.ad_creatives
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can delete ad_creatives" ON public.ad_creatives
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- ad_impressions
ALTER TABLE public.ad_impressions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_impressions" ON public.ad_impressions;
CREATE POLICY "Admins can read ad_impressions" ON public.ad_impressions
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ad_reports
ALTER TABLE public.ad_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_reports" ON public.ad_reports;
CREATE POLICY "Admins can read ad_reports" ON public.ad_reports
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ad_clicks
ALTER TABLE public.ad_clicks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_clicks" ON public.ad_clicks;
CREATE POLICY "Admins can read ad_clicks" ON public.ad_clicks
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ad_networks
ALTER TABLE public.ad_networks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_networks" ON public.ad_networks;
CREATE POLICY "Admins can read ad_networks" ON public.ad_networks
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert ad_networks" ON public.ad_networks;
CREATE POLICY "Admins can insert ad_networks" ON public.ad_networks
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update ad_networks" ON public.ad_networks;
CREATE POLICY "Admins can update ad_networks" ON public.ad_networks
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can delete ad_networks" ON public.ad_networks;
CREATE POLICY "Admins can delete ad_networks" ON public.ad_networks
FOR DELETE
TO authenticated
USING (public.is_admin_user());

-- ad_revenue_events
ALTER TABLE public.ad_revenue_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_revenue_events" ON public.ad_revenue_events;
CREATE POLICY "Admins can read ad_revenue_events" ON public.ad_revenue_events
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ============================================================================
-- COMPLETION MESSAGE
-- ============================================================================
-- All admin app permissions have been granted.
-- Please refresh the admin app to verify.
-- ============================================================================