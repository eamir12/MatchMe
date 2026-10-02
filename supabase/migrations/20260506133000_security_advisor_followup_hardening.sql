BEGIN;

-- Follow-up hardening pass based on actual direct access from the user app
-- and the admin app. This revokes authenticated/anon access by default and
-- preserves only the objects those clients query directly.

-- 1) Tighten anonymous SELECT exposure to only bootstrap/public catalog data.
DO $$
DECLARE
  v_anon_select_whitelist text[] := ARRAY[
    'app_config',
    'app_gender_options',
    'app_languages',
    'currency_exchange_rates',
    'intents',
    'interests',
    'translations'
  ];
  v_obj record;
BEGIN
  FOR v_obj IN
    SELECT n.nspname AS schema_name, c.relname AS object_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
      AND has_table_privilege('anon', format('%I.%I', n.nspname, c.relname), 'SELECT')
      AND NOT (c.relname = ANY(v_anon_select_whitelist))
  LOOP
    EXECUTE format(
      'REVOKE SELECT ON TABLE %I.%I FROM anon',
      v_obj.schema_name,
      v_obj.object_name
    );
  END LOOP;
END
$$;

-- 2) Tighten authenticated SELECT exposure to the tables/views the apps query
-- directly. Other access should go through RPCs, views exposed intentionally,
-- or service-role edge functions.
DO $$
DECLARE
  v_authenticated_select_whitelist text[] := ARRAY[
    'ad_campaigns',
    'ad_clicks',
    'ad_creatives',
    'ad_impressions',
    'ad_networks',
    'ad_reports',
    'ad_revenue_events',
    'ad_units',
    'admin_broadcast_deliveries',
    'admin_broadcasts',
    'app_config',
    'app_gender_options',
    'app_languages',
    'chat_messages',
    'chats',
    'currency_exchange_rates',
    'event_attendees',
    'events',
    'intents',
    'interests',
    'match_ratings',
    'matches',
    'message_reactions',
    'passkey_credentials',
    'profile_edit_requests',
    'promo_code_usages',
    'promo_codes',
    'referrals',
    'sensitive_action_email_codes',
    'subscription_plans',
    'subscription_tiers',
    'translations',
    'user_invisibility_rules',
    'user_locations',
    'user_profiles',
    'user_session',
    'user_subscription_queue',
    'users'
  ];
  v_obj record;
BEGIN
  FOR v_obj IN
    SELECT n.nspname AS schema_name, c.relname AS object_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
      AND has_table_privilege('authenticated', format('%I.%I', n.nspname, c.relname), 'SELECT')
      AND NOT (c.relname = ANY(v_authenticated_select_whitelist))
  LOOP
    EXECUTE format(
      'REVOKE SELECT ON TABLE %I.%I FROM authenticated',
      v_obj.schema_name,
      v_obj.object_name
    );
  END LOOP;
END
$$;

-- 3) Tighten anonymous SECURITY DEFINER RPC exposure to the tiny set that may
-- be useful before sign-in.
DO $$
DECLARE
  v_anon_execute_whitelist text[] := ARRAY[
    'check_email_availability',
    'get_promo_code_details'
  ];
  v_fn record;
BEGIN
  FOR v_fn IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_get_function_identity_arguments(p.oid) AS function_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
      AND NOT (p.proname = ANY(v_anon_execute_whitelist))
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM anon',
      v_fn.schema_name,
      v_fn.function_name,
      v_fn.function_args
    );
  END LOOP;
END
$$;

-- 4) Tighten authenticated SECURITY DEFINER RPC exposure to the RPCs the user
-- app or admin app actually calls directly.
DO $$
DECLARE
  v_authenticated_execute_whitelist text[] := ARRAY[
    'add_subscription_to_queue',
    'admin_bulk_upsert_translations',
    'admin_create_promo_code',
    'admin_delete_subscription_plan',
    'admin_delete_subscription_tier',
    'admin_delete_translation_key',
    'admin_delete_translation_locale_key',
    'admin_get_dashboard_drilldown',
    'admin_get_dashboard_stats',
    'admin_get_promo_discount_by_date',
    'admin_get_promo_usage_by_code',
    'admin_get_promo_usage_by_user',
    'admin_get_promo_usage_stats',
    'admin_get_promo_usage_user_details',
    'admin_get_user_ui_languages',
    'admin_list_external_ad_analytics_by_network',
    'admin_list_external_ad_analytics_by_placement',
    'admin_list_external_ad_analytics_by_platform',
    'admin_list_profile_edit_requests',
    'admin_list_sponsored_campaign_event_details',
    'admin_list_sponsored_campaign_metrics',
    'admin_list_sponsored_campaign_report_details',
    'admin_list_sponsored_campaign_report_summaries',
    'admin_list_target_users_for_broadcast',
    'admin_list_verification_users',
    'admin_reschedule_broadcast',
    'admin_resend_broadcast_now',
    'admin_review_profile_edit_request',
    'admin_search_users',
    'admin_set_user_verification_status',
    'admin_update_app_config',
    'admin_update_promo_code',
    'admin_update_promo_codes_config',
    'admin_upsert_subscription_plan',
    'admin_upsert_subscription_tier',
    'apply_manual_subscription_purchase',
    'apply_revenuecat_subscription',
    'block_user',
    'cancel_queued_subscription',
    'check_and_normalize_user_subscription',
    'check_email_availability',
    'check_profile_bio_uniqueness',
    'claim_referral',
    'clear_mfa_recovery_codes',
    'clear_user_subscription',
    'count_event_attendees',
    'count_target_users',
    'edit_chat_message',
    'edit_message',
    'generate_mfa_recovery_codes',
    'generate_sensitive_action_email_code',
    'get_ad_network_analytics',
    'get_broadcast_stats',
    'get_current_timestamp',
    'get_due_match_rating_prompts',
    'get_external_ad_for_placement',
    'get_message_reactors',
    'get_mfa_recovery_code_status',
    'get_nearby_users_count',
    'get_next_queued_subscription',
    'get_online_user_counts_by_country',
    'get_online_users_count',
    'get_promo_code_details',
    'get_sponsored_ad_for_placement',
    'get_subscription_cron_status',
    'get_user_ad_consent',
    'get_user_rating_summary',
    'get_user_recent_chats',
    'get_user_recent_matches',
    'get_visible_online_user_map_cells',
    'health_check',
    'mark_message_delivered',
    'mark_messages_as_read',
    'normalize_user_subscription',
    'perform_event_matching',
    'record_ad_click',
    'record_ad_impression',
    'record_external_ad_click',
    'record_external_ad_impression',
    'redeem_promo_code',
    'report_ad',
    'report_user',
    'revoke_all_passkeys',
    'revoke_all_user_sessions',
    'set_chat_translation',
    'set_match_met_answer',
    'set_message_reaction',
    'set_user_offline',
    'submit_match_rating',
    'trigger_subscription_normalization',
    'unmatch_from_system_match',
    'update_user_activity',
    'update_user_ad_consent',
    'update_user_location',
    'update_user_visibility',
    'upsert_user_session',
    'validate_promo_code'
  ];
  v_fn record;
BEGIN
  FOR v_fn IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_get_function_identity_arguments(p.oid) AS function_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND NOT (p.proname = ANY(v_authenticated_execute_whitelist))
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM authenticated',
      v_fn.schema_name,
      v_fn.function_name,
      v_fn.function_args
    );
  END LOOP;
END
$$;

COMMIT;
