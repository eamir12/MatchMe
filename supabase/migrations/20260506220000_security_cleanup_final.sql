-- Clean up: Revoke all EXECUTE from authenticated for app functions
-- Then grant EXECUTE only to service_role for admin functions
-- This ensures security while allowing the app to function
-- Migration: 20260506220000_security_cleanup_final

-- ============================================================================
-- Revoke EXECUTE from authenticated for ALL functions in public schema
-- ============================================================================

DO $$
DECLARE
    func_record RECORD;
BEGIN
    FOR func_record IN 
        SELECT DISTINCT
            p.proname as function_name
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
    LOOP
        BEGIN
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I FROM authenticated', func_record.function_name);
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I FROM anon', func_record.function_name);
        EXCEPTION WHEN others THEN
            CONTINUE;
        END;
    END LOOP;
END $$;

-- ============================================================================
-- Grant EXECUTE to service_role for admin functions only
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_password_reset_tokens() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_security_definer_functions_audit() TO service_role;

-- ============================================================================
-- Grant EXECUTE to authenticated for specific app functions
-- These are the functions the Flutter app needs to function correctly
-- Full signatures specified to handle overloaded functions
-- ============================================================================

-- Subscription functions
GRANT EXECUTE ON FUNCTION public.add_subscription_to_queue(uuid, varchar, integer, varchar, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_subscription_to_queue(uuid, varchar, integer, varchar, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_subscription_to_queue(uuid, varchar, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_next_queued_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_queued_subscription(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_subscription_normalization() TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_normalize_user_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_subscription_cron_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_revenuecat_subscription(text, timestamp with time zone, uuid) TO authenticated;

-- Chat/Messaging functions
GRANT EXECUTE ON FUNCTION public.mark_message_delivered(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_message_reaction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.block_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_user(uuid, text, text) TO authenticated;

-- User/Profile functions
GRANT EXECUTE ON FUNCTION public.claim_referral(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_referral(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_all_user_sessions(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unmatch_from_system_match(uuid) TO authenticated;

-- Matching/Rating functions
GRANT EXECUTE ON FUNCTION public.get_due_match_rating_prompts(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_match_met_answer(uuid, boolean, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_match_rating(uuid, integer, integer, integer, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_rating_summary(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO authenticated;

-- Event functions
GRANT EXECUTE ON FUNCTION public.count_event_attendees(uuid) TO authenticated;

-- Ad-related functions
GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_external_ad_for_placement(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_click(uuid, uuid, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_revenue(uuid, uuid, uuid, text, text, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_revenue(uuid, uuid, uuid, text, text, text, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_impression(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_click(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_receive_ads(uuid) TO authenticated;

-- Promo code functions
GRANT EXECUTE ON FUNCTION public.validate_promo_code(text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(text, uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_promo_code_details(text) TO authenticated;

-- Email change functions
GRANT EXECUTE ON FUNCTION public.generate_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_change(uuid, text) TO authenticated;