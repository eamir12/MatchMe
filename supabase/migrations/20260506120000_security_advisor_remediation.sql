BEGIN;

-- Remediate Supabase Security Advisor findings that can be safely fixed
-- without changing the app's authenticated client contract.

-- 1) Fix mutable search_path warnings for flagged public functions.
DO $$
DECLARE
  v_function_names text[] := ARRAY[
    '_format_mfa_recovery_code',
    '_hash_mfa_recovery_code',
    '_normalize_mfa_recovery_code',
    'add_subscription_to_queue',
    'apply_verification_decision',
    'approve_primary_photo',
    'bio_texts_too_similar',
    'check_email_availability',
    'check_unread_notifications',
    'claim_referral',
    'cleanup_expired_email_codes',
    'cleanup_orphaned_chat_messages',
    'count_target_users',
    'edit_chat_message',
    'edit_message',
    'find_shared_events',
    'generate_sensitive_action_email_code',
    'get_active_sensitive_action_email_code',
    'get_broadcast_stats',
    'get_message_reactors',
    'get_next_queued_subscription',
    'get_recent_chats',
    'get_user_chats',
    'get_user_recent_chats',
    'handle_chat_message_delete_for_chats',
    'handle_chat_message_for_chats',
    'handle_chat_message_update_for_chats',
    'handle_message_read_for_chats',
    'is_valid_currency_code_array',
    'mark_broadcast_failed',
    'mark_message_delivered',
    'mark_messages_as_read',
    'normalize_language_code',
    'normalize_profile_bio_text',
    'normalize_user_subscription_v2',
    'perform_event_matching_debug',
    'prevent_duplicate_pending_profile_edit_requests',
    'prevent_sensitive_user_field_updates',
    'process_notification_queue',
    'profile_edit_requests_set_updated_at',
    'prune_expired_sessions',
    'queue_fcm_notification',
    'recompute_reaction_summary',
    'revoke_all_user_sessions',
    'revoke_user_session',
    'set_chat_translation',
    'set_currency_exchange_rates_updated_at',
    'set_message_reaction',
    'set_promo_codes_updated_at',
    'set_row_updated_at',
    'should_delete_match_messages',
    'should_translate_message',
    'touch_user_session',
    'trigger_perform_event_matching',
    'trigger_perform_user_location_matching',
    'trigger_update_user_visibility',
    'trigger_user_proximity_matching',
    'update_admin_broadcasts_updated_at',
    'update_app_config_updated_at',
    'update_match_rating_prompts_updated_at',
    'update_notification_queue_updated_at',
    'update_subscription_tier',
    'update_user_activity',
    'update_user_location',
    'update_user_presence_updated_at',
    'update_user_rating_stats',
    'update_user_visibility',
    'upsert_chat_row',
    'upsert_user_recent_match',
    'upsert_user_session',
    'verify_sensitive_action_email_code'
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
      AND p.proname = ANY(v_function_names)
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) SET search_path TO public, auth, extensions',
      v_fn.schema_name,
      v_fn.function_name,
      v_fn.function_args
    );
  END LOOP;
END
$$;

-- 2) Revoke anonymous GraphQL discoverability from non-public objects.
DO $$
DECLARE
  v_anon_revoke_select text[] := ARRAY[
    'ad_campaigns',
    'ad_clicks',
    'ad_creatives',
    'ad_impressions',
    'ad_impressions_daily',
    'ad_network_analytics',
    'ad_networks',
    'ad_reports',
    'ad_revenue_daily_stats',
    'ad_revenue_events',
    'ad_system_config_view',
    'ad_system_schedules',
    'ad_units',
    'admin_broadcast_deliveries',
    'admin_broadcasts',
    'admin_dashboard_tick',
    'ai_quota_alert_state',
    'ai_quota_status',
    'chat_messages',
    'chats',
    'edge_function_invocations',
    'event_attendees',
    'events',
    'match_rating_prompts',
    'match_ratings',
    'matches',
    'message_reactions',
    'passkey_challenges',
    'passkey_credentials',
    'pending_email_changes',
    'presence_events',
    'profile_edit_requests',
    'promo_code_usages',
    'promo_codes',
    'referral_visits',
    'referrals',
    'sensitive_action_email_codes',
    'signup_fraud_signals',
    'subscription_plans',
    'subscription_tiers',
    'unmatched_pairs',
    'user_activity',
    'user_intents',
    'user_interests',
    'user_invisibility_rules',
    'user_locations',
    'user_mfa_recovery_codes',
    'user_profiles',
    'user_recent_matches',
    'user_session',
    'user_subscription_queue',
    'user_visibility_schedules'
  ];
  v_obj record;
BEGIN
  FOR v_obj IN
    SELECT n.nspname AS schema_name, c.relname AS object_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = ANY(v_anon_revoke_select)
      AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
  LOOP
    EXECUTE format(
      'REVOKE SELECT ON TABLE %I.%I FROM anon',
      v_obj.schema_name,
      v_obj.object_name
    );
  END LOOP;
END
$$;

-- 3) Revoke authenticated GraphQL discoverability from internal-only objects
-- that are not queried directly by the app client.
DO $$
DECLARE
  v_authenticated_revoke_select text[] := ARRAY[
    'ad_campaigns',
    'ad_clicks',
    'ad_creatives',
    'ad_impressions',
    'ad_impressions_daily',
    'ad_network_analytics',
    'ad_reports',
    'ad_system_config_view',
    'ad_system_schedules',
    'admin_broadcasts',
    'admin_dashboard_tick',
    'ai_quota_alert_state',
    'ai_quota_status',
    'edge_function_invocations',
    'match_rating_prompts',
    'passkey_challenges',
    'pending_email_changes',
    'presence_events',
    'promo_code_usages',
    'promo_codes',
    'referral_visits',
    'signup_fraud_signals',
    'subscription_plans',
    'unmatched_pairs',
    'user_activity',
    'user_intents',
    'user_interests',
    'user_mfa_recovery_codes',
    'user_recent_matches',
    'user_visibility_schedules'
  ];
  v_obj record;
BEGIN
  FOR v_obj IN
    SELECT n.nspname AS schema_name, c.relname AS object_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = ANY(v_authenticated_revoke_select)
      AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
  LOOP
    EXECUTE format(
      'REVOKE SELECT ON TABLE %I.%I FROM authenticated',
      v_obj.schema_name,
      v_obj.object_name
    );
  END LOOP;
END
$$;

-- 4) Revoke EXECUTE from anon on SECURITY DEFINER functions except the very
-- small public surface that can be called before sign-in.
DO $$
DECLARE
  v_anon_whitelist text[] := ARRAY[
    'check_email_availability',
    'count_event_attendees',
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
      AND NOT (p.proname = ANY(v_anon_whitelist))
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

-- 5) Revoke EXECUTE from authenticated on internal SECURITY DEFINER helpers
-- that should only run via service role, triggers, or other trusted functions.
DO $$
DECLARE
  v_authenticated_revoke_execute text[] := ARRAY[
    'aggregate_ad_revenue_daily',
    'aggregate_ad_revenue_last_n_days',
    'auto_translate_message_on_insert',
    'batch_translate_chat_messages',
    'broadcast_user_online_event',
    'call_translate_proxy_edge_function',
    'check_and_normalize_user_subscription',
    'cleanup_expired_matches',
    'cleanup_expired_verification_photos',
    'cleanup_notification_queue',
    'cleanup_old_presence_events',
    'cleanup_old_user_locations',
    'cleanup_orphaned_chat_messages',
    'cleanup_pending_email_changes',
    'cleanup_stale_online_users',
    'cleanup_stale_presence',
    'detect_and_broadcast_offline_users',
    'diagnose_ad_serving_for_placement',
    'diagnose_ad_serving_for_user',
    'edge_require_internal_secret',
    'edge_update_verification',
    'handle_chat_deletion_check_messages',
    'handle_message_reactions_change',
    'handle_new_match',
    'handle_user_preferred_language_change',
    'log_edge_function_invocation',
    'normalize_broadcast_filter_criteria',
    'normalize_user_subscription',
    'normalize_user_subscription_queue',
    'perform_continuous_event_matching',
    'perform_continuous_user_matching',
    'scheduled_subscription_normalization',
    'scheduled_verification_photo_cleanup',
    'sync_user_activity_on_session_change',
    'sync_users_on_auth_change',
    'touch_admin_dashboard_tick',
    'trigger_set_timestamp',
    'user_can_receive_ads'
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
      AND p.proname = ANY(v_authenticated_revoke_execute)
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

-- 6) Remove overly-broad RLS policies. service_role bypasses RLS and these
-- policies were only increasing attack surface.
DROP POLICY IF EXISTS "service_role can update chat_messages" ON public.chat_messages;
DROP POLICY IF EXISTS "Service role can manage pending email changes" ON public.pending_email_changes;
DROP POLICY IF EXISTS "Service role can update pending email changes" ON public.pending_email_changes;
DROP POLICY IF EXISTS "Match engine can create matches" ON public.matches;
DROP POLICY IF EXISTS "Allow system to insert presence events" ON public.presence_events;
DROP POLICY IF EXISTS "Public can log visits" ON public.referral_visits;

COMMIT;
