-- ============================================================================
-- Comprehensive Admin App Permissions Grant
-- Grants all necessary permissions to users with is_admin = true
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: Create/Update the is_admin_user function
-- ============================================================================

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
-- STEP 2: Enable RLS and create policies for all admin tables
-- ============================================================================

-- users table - Read access for admin
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users FOR SELECT TO authenticated USING (public.is_admin_user());

-- app_config table - Full CRUD for admins
ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read app_config" ON public.app_config;
CREATE POLICY "Admins can read app_config" ON public.app_config FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update app_config" ON public.app_config;
CREATE POLICY "Admins can update app_config" ON public.app_config FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert app_config" ON public.app_config;
CREATE POLICY "Admins can insert app_config" ON public.app_config FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());

-- subscription_tiers table - Full CRUD for admins
ALTER TABLE public.subscription_tiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can read subscription_tiers" ON public.subscription_tiers FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can insert subscription_tiers" ON public.subscription_tiers FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can update subscription_tiers" ON public.subscription_tiers FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete subscription_tiers" ON public.subscription_tiers;
CREATE POLICY "Admins can delete subscription_tiers" ON public.subscription_tiers FOR DELETE TO authenticated USING (public.is_admin_user());

-- subscription_plans table - Full CRUD for admins
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can read subscription_plans" ON public.subscription_plans FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can insert subscription_plans" ON public.subscription_plans FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can update subscription_plans" ON public.subscription_plans FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete subscription_plans" ON public.subscription_plans;
CREATE POLICY "Admins can delete subscription_plans" ON public.subscription_plans FOR DELETE TO authenticated USING (public.is_admin_user());

-- translations table - Full CRUD for admins
ALTER TABLE public.translations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read translations" ON public.translations;
CREATE POLICY "Admins can read translations" ON public.translations FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update translations" ON public.translations;
CREATE POLICY "Admins can update translations" ON public.translations FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert translations" ON public.translations;
CREATE POLICY "Admins can insert translations" ON public.translations FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete translations" ON public.translations;
CREATE POLICY "Admins can delete translations" ON public.translations FOR DELETE TO authenticated USING (public.is_admin_user());

-- admin_broadcasts table - Full CRUD for admins
ALTER TABLE public.admin_broadcasts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can read admin_broadcasts" ON public.admin_broadcasts FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can insert admin_broadcasts" ON public.admin_broadcasts FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can update admin_broadcasts" ON public.admin_broadcasts FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete admin_broadcasts" ON public.admin_broadcasts;
CREATE POLICY "Admins can delete admin_broadcasts" ON public.admin_broadcasts FOR DELETE TO authenticated USING (public.is_admin_user());

-- promo_codes table - Full CRUD for admins
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can read promo_codes" ON public.promo_codes FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can insert promo_codes" ON public.promo_codes FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can update promo_codes" ON public.promo_codes FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete promo_codes" ON public.promo_codes;
CREATE POLICY "Admins can delete promo_codes" ON public.promo_codes FOR DELETE TO authenticated USING (public.is_admin_user());

-- promo_code_usages table - Read for admins
ALTER TABLE public.promo_code_usages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read promo_code_usages" ON public.promo_code_usages;
CREATE POLICY "Admins can read promo_code_usages" ON public.promo_code_usages FOR SELECT TO authenticated USING (public.is_admin_user());

-- verification_requests table - Full CRUD for admins
ALTER TABLE public.verification_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read verification_requests" ON public.verification_requests;
CREATE POLICY "Admins can read verification_requests" ON public.verification_requests FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update verification_requests" ON public.verification_requests;
CREATE POLICY "Admins can update verification_requests" ON public.verification_requests FOR UPDATE TO authenticated USING (public.is_admin_user());

-- profile_edit_requests table - Full CRUD for admins
ALTER TABLE public.profile_edit_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can read profile_edit_requests" ON public.profile_edit_requests FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update profile_edit_requests" ON public.profile_edit_requests;
CREATE POLICY "Admins can update profile_edit_requests" ON public.profile_edit_requests FOR UPDATE TO authenticated USING (public.is_admin_user());

-- ad_campaigns table - Full CRUD for admins
ALTER TABLE public.ad_campaigns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can read ad_campaigns" ON public.ad_campaigns FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can insert ad_campaigns" ON public.ad_campaigns FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can update ad_campaigns" ON public.ad_campaigns FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete ad_campaigns" ON public.ad_campaigns;
CREATE POLICY "Admins can delete ad_campaigns" ON public.ad_campaigns FOR DELETE TO authenticated USING (public.is_admin_user());

-- ad_creatives table - Full CRUD for admins
ALTER TABLE public.ad_creatives ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can read ad_creatives" ON public.ad_creatives FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can insert ad_creatives" ON public.ad_creatives FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can update ad_creatives" ON public.ad_creatives FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete ad_creatives" ON public.ad_creatives;
CREATE POLICY "Admins can delete ad_creatives" ON public.ad_creatives FOR DELETE TO authenticated USING (public.is_admin_user());

-- ad_impressions table - Read for admins
ALTER TABLE public.ad_impressions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_impressions" ON public.ad_impressions;
CREATE POLICY "Admins can read ad_impressions" ON public.ad_impressions FOR SELECT TO authenticated USING (public.is_admin_user());

-- ad_clicks table - Read for admins
ALTER TABLE public.ad_clicks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_clicks" ON public.ad_clicks;
CREATE POLICY "Admins can read ad_clicks" ON public.ad_clicks FOR SELECT TO authenticated USING (public.is_admin_user());

-- ad_reports table - Read for admins
ALTER TABLE public.ad_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_reports" ON public.ad_reports;
CREATE POLICY "Admins can read ad_reports" ON public.ad_reports FOR SELECT TO authenticated USING (public.is_admin_user());

-- ad_revenue_events table - Read for admins
ALTER TABLE public.ad_revenue_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_revenue_events" ON public.ad_revenue_events;
CREATE POLICY "Admins can read ad_revenue_events" ON public.ad_revenue_events FOR SELECT TO authenticated USING (public.is_admin_user());

-- external_ad_events table - Read for admins
ALTER TABLE public.external_ad_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read external_ad_events" ON public.external_ad_events;
CREATE POLICY "Admins can read external_ad_events" ON public.external_ad_events FOR SELECT TO authenticated USING (public.is_admin_user());

-- external_ad_analytics table - Read for admins
ALTER TABLE public.external_ad_analytics ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read external_ad_analytics" ON public.external_ad_analytics;
CREATE POLICY "Admins can read external_ad_analytics" ON public.external_ad_analytics FOR SELECT TO authenticated USING (public.is_admin_user());

-- intents table - Full CRUD for admins
ALTER TABLE public.intents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read intents" ON public.intents;
CREATE POLICY "Admins can read intents" ON public.intents FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert intents" ON public.intents;
CREATE POLICY "Admins can insert intents" ON public.intents FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update intents" ON public.intents;
CREATE POLICY "Admins can update intents" ON public.intents FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete intents" ON public.intents;
CREATE POLICY "Admins can delete intents" ON public.intents FOR DELETE TO authenticated USING (public.is_admin_user());

-- interests table - Full CRUD for admins
ALTER TABLE public.interests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read interests" ON public.interests;
CREATE POLICY "Admins can read interests" ON public.interests FOR SELECT TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can insert interests" ON public.interests;
CREATE POLICY "Admins can insert interests" ON public.interests FOR INSERT TO authenticated WITH CHECK (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can update interests" ON public.interests;
CREATE POLICY "Admins can update interests" ON public.interests FOR UPDATE TO authenticated USING (public.is_admin_user());
DROP POLICY IF EXISTS "Admins can delete interests" ON public.interests;
CREATE POLICY "Admins can delete interests" ON public.interests FOR DELETE TO authenticated USING (public.is_admin_user());

-- ============================================================================
-- STEP 3: Grant execute on all admin functions
-- ============================================================================

DO $$
DECLARE
  func_record RECORD;
  admin_functions TEXT[] := ARRAY[
    'admin_get_dashboard_stats',
    'admin_get_dashboard_drilldown',
    'admin_list_intents',
    'admin_list_interests',
    'admin_upsert_intent',
    'admin_upsert_interest',
    'admin_delete_intent',
    'admin_delete_interest',
    'admin_bulk_upsert_translations',
    'admin_delete_translation_key',
    'admin_delete_translation_locale_key',
    'admin_list_target_users_for_broadcast',
    'admin_resend_broadcast_now',
    'admin_reschedule_broadcast',
    'count_target_users',
    'get_broadcast_stats',
    'admin_get_user_ui_languages',
    'admin_search_users',
    'admin_upsert_subscription_tier',
    'admin_delete_subscription_tier',
    'admin_upsert_subscription_plan',
    'admin_delete_subscription_plan',
    'admin_update_app_config',
    'admin_list_verification_users',
    'admin_set_user_verification_status',
    'admin_list_profile_edit_requests',
    'admin_review_profile_edit_request',
    'admin_list_sponsored_campaign_metrics',
    'admin_list_sponsored_campaign_report_summaries',
    'admin_list_sponsored_campaign_event_details',
    'admin_list_sponsored_campaign_report_details',
    'admin_list_recent_sponsored_ad_reports',
    'admin_list_external_ad_analytics_by_platform',
    'admin_list_external_ad_analytics_by_network',
    'admin_list_external_ad_analytics_by_placement',
    'admin_list_external_ad_events',
    'admin_list_external_ad_event_details',
    'admin_create_promo_code',
    'admin_update_promo_code',
    'admin_get_promo_usage_by_user',
    'admin_get_promo_usage_by_code',
    'admin_get_promo_discount_by_date',
    'admin_get_promo_usage_stats',
    'admin_update_promo_codes_config',
    'admin_get_ai_quota_status',
    'is_admin_user'
  ];
  func_name TEXT;
BEGIN
  FOREACH func_name IN ARRAY admin_functions
  LOOP
    FOR func_record IN 
      SELECT proname, pg_get_function_identity_arguments(oid) as args
      FROM pg_proc 
      WHERE proname = func_name AND pronamespace = 'public'::regnamespace
    LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                     func_record.proname, func_record.args);
    END LOOP;
  END LOOP;
END $$;

COMMIT;

-- ============================================================================
-- Verification: Check permissions are set up correctly
-- ============================================================================

-- Show current admin policies
SELECT tablename, policyname, cmd FROM pg_policies 
WHERE schemaname = 'public' AND policyname LIKE 'Admins can%'
ORDER BY tablename;

-- Show function permissions for admin functions
SELECT proname, pg_get_userbyid(a.grantee) as grantee, a.privilege_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN aclexplode(p.proacl) a ON true
WHERE n.nspname = 'public' 
  AND (p.proname LIKE 'admin_%' OR p.proname = 'is_admin_user')
  AND pg_get_userbyid(a.grantee) = 'authenticated'
ORDER BY proname;