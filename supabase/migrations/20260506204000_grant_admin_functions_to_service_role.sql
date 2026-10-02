-- Additional fixes for timestamp-based function variants and any overloads

-- Admin Analytics Functions - Timestamp variants
REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamp with time zone, timestamp with time zone) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_platform(timestamp with time zone, timestamp with time zone) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamp with time zone, timestamp with time zone) FROM authenticated;

-- Ensure proper grants to service_role for backend operations
GRANT EXECUTE ON FUNCTION public.admin_upsert_subscription_tier TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_subscription_tier TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_upsert_subscription_plan TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_subscription_plan TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_bulk_upsert_translations TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_translation_key TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_translation_locale_key TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_verification_users TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_profile_edit_requests TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_review_profile_edit_request TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_search_users TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_promo_code TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_discount_by_date TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_by_code TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_by_user TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_stats TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_user_details TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_promo_codes_config(boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_intents TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_interests TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_upsert_intent TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_upsert_interest TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_intent TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_interest TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast TO service_role;
GRANT EXECUTE ON FUNCTION public.send_admin_broadcast TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_reschedule_broadcast TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_dashboard_stats TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_dashboard_drilldown TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_metrics TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_details TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_event_details TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_app_config TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_user_ui_languages TO service_role;
