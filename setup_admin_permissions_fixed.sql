-- ============================================================================
-- Comprehensive Admin App Permissions Setup
-- ============================================================================
-- This script sets up all necessary permissions for the admin app to function
-- correctly for user: ffc20046-a777-463b-922a-547151aa1455
-- Based on actual code analysis of matchme_admin app
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: Ensure the admin user has is_admin = true
-- ============================================================================
UPDATE public.users 
SET is_admin = true 
WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- ============================================================================
-- STEP 2: Create or replace the is_admin_user function
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
-- STEP 3: Set up RLS policies for tables actually accessed by admin app
-- ============================================================================

-- users table - Read access for admin check (found in main.dart)
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- app_config table - Read/Update for admins (found in sponsored_ads_dashboard.dart)
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

-- ad_campaigns table - Full CRUD for admins (found in sponsored_ads_dashboard.dart)
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

-- ad_creatives table - Full CRUD for admins (found in sponsored_ads_dashboard.dart)
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

-- ad_impressions table - Read access for admins (found in sponsored_ads_dashboard.dart)
ALTER TABLE public.ad_impressions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_impressions" ON public.ad_impressions;
CREATE POLICY "Admins can read ad_impressions" ON public.ad_impressions
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ad_clicks table - Read access for admins (found in sponsored_ads_dashboard.dart)
ALTER TABLE public.ad_clicks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_clicks" ON public.ad_clicks;
CREATE POLICY "Admins can read ad_clicks" ON public.ad_clicks
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ad_reports table - Read access for admins (found in sponsored_ads_dashboard.dart)
ALTER TABLE public.ad_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can read ad_reports" ON public.ad_reports;
CREATE POLICY "Admins can read ad_reports" ON public.ad_reports
FOR SELECT
TO authenticated
USING (public.is_admin_user());

-- ============================================================================
-- STEP 4: Grant execute permissions on admin RPC functions actually called
-- ============================================================================

-- Grant execute on specific admin functions found in main.dart
DO $$
DECLARE
  func_record RECORD;
BEGIN
  -- admin_get_dashboard_stats
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_get_dashboard_stats' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- count_target_users
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'count_target_users' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- admin_resend_broadcast_now
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_resend_broadcast_now' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- get_broadcast_stats
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'get_broadcast_stats' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- admin_bulk_upsert_translations
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_bulk_upsert_translations' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- admin_delete_translation_key
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_translation_key' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- admin_delete_subscription_tier
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_delete_subscription_tier' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- admin_update_promo_code (found in promo_code_dashboard.dart)
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_update_promo_code' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  -- sponsored ads RPC functions (found in sponsored_ads_dashboard.dart)
  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_metrics' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_report_summaries' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_event_details' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_sponsored_campaign_report_details' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

  FOR func_record IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args
    FROM pg_proc 
    WHERE proname = 'admin_list_recent_sponsored_ad_reports' AND pronamespace = 'public'::regnamespace
    LIMIT 1
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', 
                   func_record.proname, func_record.args);
  END LOOP;

END $$;

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Verify admin user status
SELECT id, email, is_admin FROM public.users WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Verify is_admin_user function works
SELECT public.is_admin_user('ffc20046-a777-463b-922a-547151aa1455') as is_admin_check;

-- Verify admin policies are in place
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND policyname LIKE 'Admins can%'
ORDER BY tablename, policyname;