-- ============================================================================
-- Fix: Admin app cannot reset or change a user's verification status
--
-- Root cause:
--   The admin Flutter app authenticates as a regular user (anon key + user
--   JWT, i.e. the `authenticated` role) and calls admin RPCs through
--   PostgREST. Migration 20260506202000_revoke_admin_functions_from_authenticated.sql
--   revoked EXECUTE on admin_set_user_verification_status (and many other
--   admin functions) from `authenticated`, and migration
--   20260506220000_security_cleanup_final.sql revoked EXECUTE on ALL public
--   functions from `authenticated` while only re-granting the user-app
--   whitelist. The later DO-loop migration
--   20260627000001_grant_admin_rpcs_to_authenticated.sql attempted to restore
--   `admin_%` functions but only covers that prefix, skips failures silently
--   (proven unreliable by 20260630000001, which had to explicitly re-grant
--   admin_list_profile_edit_requests), and does not cover the non-admin_-
--   prefixed functions the admin app also calls (count_target_users,
--   get_broadcast_stats, get_current_timestamp, send_admin_broadcast).
--
--   Result: PostgREST returns 403 "permission denied for function
--   admin_set_user_verification_status", so the admin cannot approve, reject,
--   or reset a user's verification status.
--
-- Fix:
--   1. Recreate admin_set_user_verification_status (latest version) which
--      sets the service_role JWT claim inside the transaction so the
--      block_protected_user_fields_update trigger lets the admin RPC update
--      the protected verification columns.
--   2. Re-grant EXECUTE to `authenticated` for every RPC the admin app
--      calls. Grants are issued per overload (identity argument list) because
--      some function names are overloaded in the deployed database (e.g.
--      admin_update_promo_code), and `GRANT ... ON FUNCTION name` without an
--      argument list fails with 42725 "function is not unique" in that case.
--      Idempotent; also fixes the same permission failure for broadcast
--      target counting, broadcast stats, the offline sync connectivity probe,
--      and all other admin functions.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. admin_set_user_verification_status (latest version with trigger bypass)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_set_user_verification_status(
  p_user_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'p_status is required';
  END IF;

  IF v_status NOT IN ('unverified', 'analyzing', 'pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid status';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  UPDATE public.users u
  SET
    verification_status = v_status,
    is_verified = (v_status = 'approved'),
    verification_reviewed_at = CASE WHEN v_status IN ('approved', 'rejected') THEN now() ELSE NULL END,
    verification_reviewer_id = CASE WHEN v_status IN ('approved', 'rejected') THEN auth.uid() ELSE NULL END,
    verification_photo_retention_until = CASE
      WHEN v_status = 'approved' THEN now() + interval '30 days'
      WHEN v_status = 'pending' THEN now() + interval '14 days'
      WHEN v_status = 'rejected' THEN now() + interval '7 days'
      ELSE NULL
    END
  WHERE u.id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO service_role;

-- ============================================================================
-- 2. Restore EXECUTE for `authenticated` on every RPC used by the admin app.
--    Grants each existing overload of every listed function name, so the
--    migration succeeds regardless of which overloads exist on the database.
-- ============================================================================

DO $$
DECLARE
  v_name text;
  func_record RECORD;
  v_names text[] := ARRAY[
    -- Verification & profile edit review
    'admin_list_verification_users',
    'admin_list_profile_edit_requests',
    'admin_review_profile_edit_request',
    'admin_search_users',
    -- Dashboard
    'admin_get_dashboard_stats',
    'admin_get_dashboard_drilldown',
    -- Translations
    'admin_bulk_upsert_translations',
    'admin_delete_translation_key',
    'admin_delete_translation_locale_key',
    -- Subscriptions
    'admin_upsert_subscription_tier',
    'admin_delete_subscription_tier',
    'admin_upsert_subscription_plan',
    'admin_delete_subscription_plan',
    -- Taxonomy (intents & interests)
    'admin_list_intents',
    'admin_list_interests',
    'admin_upsert_intent',
    'admin_upsert_interest',
    'admin_delete_intent',
    'admin_delete_interest',
    -- Broadcasts (incl. non-admin_-prefixed RPCs the admin app calls)
    'admin_list_target_users_for_broadcast',
    'admin_resend_broadcast_now',
    'admin_reschedule_broadcast',
    'send_admin_broadcast',
    'count_target_users',
    'get_broadcast_stats',
    -- Promo codes
    'admin_create_promo_code',
    'admin_update_promo_code',
    'admin_update_promo_codes_config',
    'admin_get_promo_usage_by_user',
    'admin_get_promo_usage_by_code',
    'admin_get_promo_discount_by_date',
    'admin_get_promo_usage_user_details',
    'admin_get_promo_usage_stats',
    -- Sponsored ads
    'admin_list_sponsored_campaign_metrics',
    'admin_list_sponsored_campaign_report_summaries',
    'admin_list_sponsored_campaign_report_details',
    'admin_list_sponsored_campaign_event_details',
    'admin_list_recent_sponsored_ad_reports',
    -- External ads
    'admin_list_external_ad_analytics_by_network',
    'admin_list_external_ad_analytics_by_platform',
    'admin_list_external_ad_analytics_by_placement',
    'admin_list_external_ad_event_details',
    -- Config, language & misc
    'admin_update_app_config',
    'admin_get_user_ui_languages',
    'admin_get_ai_quota_status',
    'get_current_timestamp'
  ];
BEGIN
  FOREACH v_name IN ARRAY v_names LOOP
    FOR func_record IN
      SELECT p.oid, p.proname
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname = 'public'
        AND p.proname = v_name
    LOOP
      BEGIN
        EXECUTE format(
          'GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated',
          func_record.proname,
          pg_get_function_identity_arguments(func_record.oid)
        );
      EXCEPTION WHEN others THEN
        RAISE WARNING 'Could not grant EXECUTE on %(%), skipping: %',
          func_record.proname,
          pg_get_function_identity_arguments(func_record.oid),
          SQLERRM;
      END;
    END LOOP;
  END LOOP;
END $$;

-- admin_list_external_ad_events exists only on some deployments; grant
-- conditionally so the migration never fails on databases without it.
DO $$
DECLARE
  func_record RECORD;
BEGIN
  FOR func_record IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'admin_list_external_ad_events'
  LOOP
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated',
      func_record.proname,
      pg_get_function_identity_arguments(func_record.oid)
    );
  END LOOP;
END $$;

COMMIT;