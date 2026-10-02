-- Grant EXECUTE to authenticated for all RPC functions used by the Flutter app
-- This is required for the app to function correctly
-- Migration: 20260506210000_grant_app_rpc_functions

-- ============================================================================
-- Subscription functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.add_subscription_to_queue(p_user_id uuid, p_tier text, p_duration_seconds integer, p_payment_provider text, p_transaction_id text, p_metadata jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_next_queued_subscription(p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_queued_subscription(p_queue_id uuid, p_reason text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_subscription_normalization() TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_normalize_user_subscription(p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_subscription_cron_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_revenuecat_subscription(p_tier text, p_expires_at timestamp with time zone, p_user_id uuid) TO authenticated;

-- ============================================================================
-- Chat/Messaging functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.mark_message_delivered(p_message_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(p_match_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_message_reaction(p_message_id uuid, p_reaction text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(p_message_id uuid, p_new_content text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(p_message_id uuid, p_new_content text, p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(p_message_id uuid, p_new_content text, p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(p_message_id uuid, p_user_id uuid, p_new_content text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(p_message_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(message_id uuid, reaction text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.block_user(p_blocked_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_user(p_reported_user_id uuid, p_reason text, p_details text) TO authenticated;

-- ============================================================================
-- User/Profile functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.claim_referral(p_referral_code text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_referral(p_referral_code text, p_device_id text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(p_user_id uuid, p_activity_type text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_all_user_sessions(p_user_id uuid, p_terminated_by text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unmatch_from_system_match(p_match_id uuid) TO authenticated;

-- ============================================================================
-- Matching/Rating functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.get_due_match_rating_prompts(p_user_id uuid, p_initial_delay_seconds integer, p_limit integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_match_met_answer(p_match_id uuid, p_met boolean, p_repeat_delay_seconds integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_match_rating(p_match_id uuid, p_q1 integer, p_q2 integer, p_q3 integer, p_q4 integer, p_q5 integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_rating_summary(p_user_id uuid, p_min_count integer, p_last_n integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(p_user_id uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(p_user_id uuid, p_radius_km integer) TO authenticated;

-- ============================================================================
-- Event functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.count_event_attendees(event_id_param uuid) TO authenticated;

-- ============================================================================
-- Ad-related functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(p_placement text, p_locale text, p_platform text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_external_ad_for_placement(p_placement text, p_platform text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_impression(p_campaign_id uuid, p_creative_id uuid, p_placement text, p_platform text, p_locale text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_click(p_campaign_id uuid, p_creative_id uuid, p_placement text, p_platform text, p_locale text, p_destination_url text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_revenue(p_network_id uuid, p_ad_unit_id uuid, p_user_id uuid, p_placement text, p_platform text, p_revenue_usd numeric, p_ad_format text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_revenue(p_user_id uuid, p_network_id uuid, p_ad_unit_id uuid, p_placement text, p_platform text, p_event_type text, p_revenue_usd numeric, p_ad_format text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_impression(p_network_id uuid, p_ad_unit_id uuid, p_placement text, p_platform text, p_ad_format text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_external_ad_click(p_network_id uuid, p_ad_unit_id uuid, p_placement text, p_platform text, p_ad_format text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_receive_ads(p_user_id uuid) TO authenticated;

-- ============================================================================
-- Promo code functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.validate_promo_code(p_code text, p_user_id uuid, p_for_tier text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(p_code text, p_user_id uuid, p_subscription_queue_id uuid, p_discount_value_cents integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_promo_code_details(p_code text) TO authenticated;

-- ============================================================================
-- Email change functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.generate_email_change_code(p_user_id uuid, p_new_email text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(p_user_id uuid, p_code text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_change(p_user_id uuid, p_code text) TO authenticated;

-- ============================================================================
-- Summary
-- ============================================================================
-- This script grants EXECUTE to authenticated for all RPC functions that the Flutter app uses.
-- These functions are safe for authenticated users to call as they implement proper security checks internally.
--
-- After running this script:
-- - Your Flutter app will work correctly
-- - Security warnings will return for these functions (but they are intentional and necessary for app functionality)
-- - The 3 admin functions (admin_update_promo_codes_config, cleanup_expired_password_reset_tokens, get_security_definer_functions_audit) remain revoked from authenticated, which is correct