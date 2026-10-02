-- ============================================================================
-- Grant Admin App Permissions (Precise Version)
-- ============================================================================
-- This script grants the necessary permissions for the admin app to function.
-- Based on actual database structure analysis.
-- ============================================================================

BEGIN;

-- ============================================================================
-- TABLE PERMISSIONS
-- ============================================================================

-- users: Read access for admin users (to check is_admin and other fields)
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
USING (public.is_admin_user());

-- intents: Read access for admin users
DROP POLICY IF EXISTS "Admins can read intents" ON public.intents;
CREATE POLICY "Admins can read intents" ON public.intents
FOR SELECT
USING (public.is_admin_user());

-- interests: Read access for admin users
DROP POLICY IF EXISTS "Admins can read interests" ON public.interests;
CREATE POLICY "Admins can read interests" ON public.interests
FOR SELECT
USING (public.is_admin_user());

-- translations: Full CRUD access for admin users
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

-- subscription_tiers: Full CRUD access for admin users
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

-- subscription_plans: Full CRUD access for admin users
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

-- profile_edit_requests: Full CRUD access for admin users
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

-- ============================================================================
-- FUNCTION PERMISSIONS
-- ============================================================================

-- Grant execute on admin functions using actual signatures from database

DO $$
DECLARE
  func_record RECORD;
BEGIN
  -- Dashboard functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_dashboard_stats' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_dashboard_drilldown' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Intents/Interests functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_intents' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_interests' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_upsert_intent' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_upsert_interest' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_intent' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_interest' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Translation functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_bulk_upsert_translations' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_translation_key' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_translation_locale_key' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Broadcast functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_target_users_for_broadcast' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_resend_broadcast_now' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_reschedule_broadcast' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'count_target_users' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'get_broadcast_stats' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- User functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_user_ui_languages' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_search_users' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Subscription functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_upsert_subscription_tier' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_subscription_tier' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_upsert_subscription_plan' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_subscription_plan' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- App config functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_update_app_config' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Verification functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_verification_users' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_set_user_verification_status' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Profile edit functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_profile_edit_requests' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_review_profile_edit_request' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Sponsored ads functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_metrics' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_report_summaries' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_event_details' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_report_details' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_recent_sponsored_ad_reports' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- External ads functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_external_ad_analytics_by_platform' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_external_ad_analytics_by_network' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_external_ad_analytics_by_placement' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_external_ad_events' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_external_ad_event_details' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Promo code functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_create_promo_code' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_update_promo_code' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_promo_usage_by_user' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_promo_usage_by_code' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_promo_discount_by_date' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_promo_usage_stats' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_promo_usage_user_details' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_update_promo_codes_config' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- AI quota function
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_ai_quota_status' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;

  -- Utility functions
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'get_current_timestamp' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', func_record.proname, func_record.args);
  END LOOP;
END $$;

COMMIT;

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================

-- Check that admin policies are in place
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND policyname LIKE 'Admins can%'
ORDER BY tablename, policyname;