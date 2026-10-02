-- Revoke EXECUTE on all admin functions from authenticated role
-- Defense-in-depth: Prevent non-admin users from calling admin functions at database level
-- This complements the is_admin checks within the functions themselves

-- Admin Subscription Management
REVOKE EXECUTE ON FUNCTION public.admin_upsert_subscription_tier(text, text, text, text, text, text, int, boolean) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_subscription_tier(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_subscription_plan(text, text, text, text, text, text, int) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_subscription_plan(text) FROM authenticated;

-- Admin Translation Management
REVOKE EXECUTE ON FUNCTION public.admin_bulk_upsert_translations(jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_translation_key(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_translation_locale_key(text, text) FROM authenticated;

-- Admin User & Verification Management
REVOKE EXECUTE ON FUNCTION public.admin_list_verification_users(text, text, integer, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_review_profile_edit_request(uuid, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) FROM authenticated;

-- Admin Promo Code Management
REVOKE EXECUTE ON FUNCTION public.admin_create_promo_code(text, text, text, integer, text, text[], text, integer, integer, timestamp with time zone, timestamp with time zone, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_promo_discount_by_date() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_promo_usage_by_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_promo_usage_by_user() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_promo_usage_stats(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_promo_usage_user_details(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_update_promo_codes_config(boolean) FROM authenticated;

-- Admin Taxonomy Management (Intents & Interests)
REVOKE EXECUTE ON FUNCTION public.admin_list_intents() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_interests() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_intent(text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_interest(text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_intent(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_interest(text) FROM authenticated;

-- Admin Broadcast System
REVOKE EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.send_admin_broadcast(uuid, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_reschedule_broadcast(uuid, timestamp with time zone) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid) FROM authenticated;

-- Admin Dashboard & Analytics
REVOKE EXECUTE ON FUNCTION public.admin_get_dashboard_stats(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_dashboard_drilldown(text, text, text, integer, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_metrics() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_details(uuid, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_event_details(uuid, text, integer) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(date, date) FROM authenticated;

-- Admin Configuration
REVOKE EXECUTE ON FUNCTION public.admin_update_app_config(text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_user_ui_languages(uuid[]) FROM authenticated;

-- NOTE: Grant these only to service_role and authenticated users who pass the is_admin check
-- By revoking from authenticated, the REST API will return 403 Forbidden immediately
-- This prevents API exhaustion and information leakage before the function runs
