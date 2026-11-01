-- Migration: remove anonymous EXECUTE on every SECURITY DEFINER function.
-- Date: 2026-10-29
--
-- Problem: 128 SECURITY DEFINER functions in public are executable by anon.
-- Most inherit it from the default PUBLIC grant, some hold an explicit anon
-- entry. SECURITY DEFINER bypasses RLS, so a caller holding only the public
-- anon key runs these with the owner's rights.
--
-- Reproduced against production on 2026-10-29 with the anon key:
--   GET  /rest/v1/user_activity             -> 200, real user ids returned
--   POST /rest/v1/rpc/update_user_activity  -> 204 for an arbitrary uuid
--   POST /rest/v1/rpc/update_user_location  -> moves / pins any user
--
-- No application flow needs anon EXECUTE here. Signup and password reset run
-- through secure-sign-up / password-reset-otp on the service role, and every
-- client RPC fires from a signed-in session. The anon key is only used to
-- reach GoTrue and PostgREST as anon for reads that RLS already filters.
--
-- Fix: REVOKE EXECUTE FROM PUBLIC, anon on every SECURITY DEFINER function in
-- public, then restate the grants that signed-in and service traffic already
-- had, so the effective permission set of authenticated and service_role is
-- unchanged. 127 of the 128 keep service_role; account_exists never had it.
--
-- Blast radius: function ACLs only. No body, signature, owner, volatility or
-- default changes. Reversible per function with a single GRANT.
--
-- Verification (run after applying):
--   select p.proname, pg_get_function_identity_arguments(p.oid)
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.prosecdef
--     and has_function_privilege('anon', p.oid, 'EXECUTE');
--   -- expect 0 rows

-- generated from pg_proc on 2026-10-29


-- location writers (4)

REVOKE EXECUTE ON FUNCTION public.extend_pinned_location(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.extend_pinned_location(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.extend_pinned_location(uuid, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.pin_current_location(uuid, double precision, double precision, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pin_current_location(uuid, double precision, double precision, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pin_current_location(uuid, double precision, double precision, text, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.unpin_location(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unpin_location(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unpin_location(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.update_user_location(uuid, double precision, double precision, double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_user_location(uuid, double precision, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_location(uuid, double precision, double precision, double precision, double precision) TO service_role;


-- presence and visibility writers (3)

REVOKE EXECUTE ON FUNCTION public.broadcast_user_online_event(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.broadcast_user_online_event(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.broadcast_user_online_event(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.update_user_activity(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.update_user_visibility(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_visibility(uuid) TO service_role;


-- admin and verification writers (22)

REVOKE EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_match(uuid, boolean) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_delete_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_health_errors() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_health_errors() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_health_errors() TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_health_history(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_health_history(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_health_history(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_match_pair_status(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_match_pair_status(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_match_pair_status(uuid, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_promo_discount_by_date(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_discount_by_date(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_discount_by_date(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_promo_usage_by_code(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_by_code(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_by_code(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_promo_usage_by_user(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_by_user(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_promo_usage_by_user(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_realtime_user_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_realtime_user_counts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_realtime_user_counts() TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_user_map_locations(text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_network(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_analytics_by_placement(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_event_details(text, text, date, date, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_external_ad_events(uuid, text, text, date, date, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_events(uuid, text, text, date, date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_external_ad_events(uuid, text, text, date, date, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries(timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries(timestamp with time zone, timestamp with time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_sponsored_campaign_report_summaries(timestamp with time zone, timestamp with time zone) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_list_verification_users(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_verification_users(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_verification_users(text, text, integer, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_search_match_users(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_match_users(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_match_users(text, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_search_matches(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_matches(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_matches(text, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) TO service_role;


-- maintenance jobs (8)

REVOKE EXECUTE ON FUNCTION public.cleanup_expired_offline_trail() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_offline_trail() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_offline_trail() TO service_role;

REVOKE EXECUTE ON FUNCTION public.cleanup_pending_email_changes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cleanup_pending_email_changes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_pending_email_changes() TO service_role;

REVOKE EXECUTE ON FUNCTION public.cleanup_stale_live_share_sessions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_live_share_sessions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_live_share_sessions() TO service_role;

REVOKE EXECUTE ON FUNCTION public.detect_and_broadcast_offline_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.detect_and_broadcast_offline_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.detect_and_broadcast_offline_users() TO service_role;

REVOKE EXECUTE ON FUNCTION public.expire_pinned_locations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.expire_pinned_locations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.expire_pinned_locations() TO service_role;

REVOKE EXECUTE ON FUNCTION public.prune_admin_health_snapshots() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prune_admin_health_snapshots() TO authenticated;
GRANT EXECUTE ON FUNCTION public.prune_admin_health_snapshots() TO service_role;

REVOKE EXECUTE ON FUNCTION public.touch_active_pinned_locations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_active_pinned_locations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.touch_active_pinned_locations() TO service_role;

REVOKE EXECUTE ON FUNCTION public.touch_presence_tick() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_presence_tick() TO authenticated;
GRANT EXECUTE ON FUNCTION public.touch_presence_tick() TO service_role;


-- read RPCs (16)

REVOKE EXECUTE ON FUNCTION public.get_country_from_coords(double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_country_from_coords(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_country_from_coords(double precision, double precision) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_due_match_rating_prompts(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_due_match_rating_prompts(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_due_match_rating_prompts(uuid, integer, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_masked_sender_name(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_match_extension_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_match_extension_status(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_match_extension_status(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision, double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, double precision, double precision, double precision) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_online_dashboard_stats(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_online_dashboard_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_dashboard_stats(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_online_others_count(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_others_count(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country(integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_online_user_counts_by_country_excluding_self(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country_excluding_self(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_user_counts_by_country_excluding_self(uuid, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_online_users_count(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_peer_chat_public_keys(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_peer_chat_public_keys(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_peer_chat_public_keys(uuid[]) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_promo_code_details(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_promo_code_details(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_promo_code_details(text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_user_active_chat_key(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_active_chat_key(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_active_chat_key(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid, integer) TO service_role;


-- user-scoped RPCs (75)

REVOKE EXECUTE ON FUNCTION public._append_location_history(uuid, uuid, integer, double precision, double precision, double precision, text, timestamp with time zone, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._append_location_history(uuid, uuid, integer, double precision, double precision, double precision, text, timestamp with time zone, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public._append_location_history(uuid, uuid, integer, double precision, double precision, double precision, text, timestamp with time zone, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public._get_config_numeric(text, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._get_config_numeric(text, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public._get_config_numeric(text, numeric, numeric, numeric) TO service_role;

REVOKE EXECUTE ON FUNCTION public._get_max_match_occurrence() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._get_max_match_occurrence() TO authenticated;
GRANT EXECUTE ON FUNCTION public._get_max_match_occurrence() TO service_role;

REVOKE EXECUTE ON FUNCTION public._match_effective_extension_seconds(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._match_effective_extension_seconds(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public._match_effective_extension_seconds(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public._match_effective_window_seconds(matches) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._match_effective_window_seconds(matches) TO authenticated;
GRANT EXECUTE ON FUNCTION public._match_effective_window_seconds(matches) TO service_role;

REVOKE EXECUTE ON FUNCTION public._match_expires_at(matches) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._match_expires_at(matches) TO authenticated;
GRANT EXECUTE ON FUNCTION public._match_expires_at(matches) TO service_role;

REVOKE EXECUTE ON FUNCTION public._match_extended_text(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._match_extended_text(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public._match_extended_text(text, text, text, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public._match_rating_prompt_due_at(matches, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._match_rating_prompt_due_at(matches, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public._match_rating_prompt_due_at(matches, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public._purge_offline_trail_on_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._purge_offline_trail_on_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public._purge_offline_trail_on_settings() TO service_role;

REVOKE EXECUTE ON FUNCTION public.accept_live_share_invite(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_live_share_invite(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_live_share_invite(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.account_exists(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.account_exists(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.check_all_due_rating_prompts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_all_due_rating_prompts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_all_due_rating_prompts() TO service_role;

REVOKE EXECUTE ON FUNCTION public.check_profile_bio_uniqueness(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_profile_bio_uniqueness(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_profile_bio_uniqueness(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.claim_onboarding_core_tour() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_onboarding_core_tour() TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_onboarding_core_tour() TO service_role;

REVOKE EXECUTE ON FUNCTION public.clear_user_session_wns_channel(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_user_session_wns_channel(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_user_session_wns_channel(text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.complete_email_change(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_email_change(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_change(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.consume_ai_rate_limit(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.consume_ai_rate_limit(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_ai_rate_limit(text, text, integer, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.create_live_share_invite(uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_live_share_invite(uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_live_share_invite(uuid, uuid, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.create_or_replace_chat_key_wrapper(uuid, text, text, integer, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_or_replace_chat_key_wrapper(uuid, text, text, integer, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_or_replace_chat_key_wrapper(uuid, text, text, integer, text, text, text, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.delete_event_when_last_attendee_leaves() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_event_when_last_attendee_leaves() TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_event_when_last_attendee_leaves() TO service_role;

REVOKE EXECUTE ON FUNCTION public.delete_my_offline_trail() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_my_offline_trail() TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_offline_trail() TO service_role;

REVOKE EXECUTE ON FUNCTION public.edit_chat_message(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, jsonb, uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, jsonb, uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, jsonb, uuid, uuid, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, text, jsonb, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, text, jsonb, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, text, text, jsonb, text, text, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.edit_message(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, text, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.edit_message(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.end_live_share_session(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.end_live_share_session(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.end_live_share_session(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.extend_match_chat_window(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.extend_match_chat_window(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.extend_match_chat_window(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.force_normalize_subscription(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.force_normalize_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.force_normalize_subscription(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.generate_email_change_code(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_email_change_code(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.handle_chat_message_delete_for_chats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handle_chat_message_delete_for_chats() TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_chat_message_delete_for_chats() TO service_role;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO service_role;

REVOKE EXECUTE ON FUNCTION public.health_check() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;
GRANT EXECUTE ON FUNCTION public.health_check() TO service_role;

REVOKE EXECUTE ON FUNCTION public.is_admin_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin_user(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.is_pinned_location_active(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_pinned_location_active(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_pinned_location_active(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.is_user_online(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_user_online(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_online(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.is_user_online_realtime(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_user_online_realtime(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_online_realtime(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.is_user_truly_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.is_user_truly_visible_realtime(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible_realtime(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible_realtime(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_profile_field_change() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_profile_field_change() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_profile_field_change() TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_user_visibility_state_change() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_user_visibility_state_change() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_user_visibility_state_change() TO service_role;

REVOKE EXECUTE ON FUNCTION public.mask_full_name(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mask_full_name(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mask_full_name(text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.normalize_user_subscription(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.normalize_user_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_user_subscription(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_event_match_attendance() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_event_match_attendance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_event_match_attendance() TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_location_share_started() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_location_share_started() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_location_share_started() TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_match_extended(uuid, uuid, timestamp with time zone, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_match_extended(uuid, uuid, timestamp with time zone, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_match_extended(uuid, uuid, timestamp with time zone, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_matched_attendance() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_matched_attendance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_matched_attendance() TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_meetup_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_meetup_session() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_meetup_session() TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_meetup_signal() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_meetup_signal() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_meetup_signal() TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_meetup_spot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_meetup_spot() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_meetup_spot() TO service_role;

REVOKE EXECUTE ON FUNCTION public.notify_rating_summary_changed() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_rating_summary_changed() TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_rating_summary_changed() TO service_role;

REVOKE EXECUTE ON FUNCTION public.online_presence_user_ids(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_presence_user_ids(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.online_presence_user_ids(integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.perform_continuous_user_matching() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO service_role;

REVOKE EXECUTE ON FUNCTION public.perform_event_matching(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perform_event_matching(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_event_matching(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.perform_event_matching_debug(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perform_event_matching_debug(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_event_matching_debug(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.redeem_promo_code(text, uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(text, uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(text, uuid, uuid, integer) TO service_role;

REVOKE EXECUTE ON FUNCTION public.replace_lost_chat_key(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_lost_chat_key(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.replace_lost_chat_key(uuid, text, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.report_client_error(text, text, uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, uuid, text, jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.request_verification_manual_review() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_verification_manual_review() TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_verification_manual_review() TO service_role;

REVOKE EXECUTE ON FUNCTION public.revoke_live_share_invite(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_live_share_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_live_share_invite(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.set_match_window_snapshot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_match_window_snapshot() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_match_window_snapshot() TO service_role;

REVOKE EXECUTE ON FUNCTION public.set_user_location_country() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_user_location_country() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_location_country() TO service_role;

REVOKE EXECUTE ON FUNCTION public.sync_pinned_location_to_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_pinned_location_to_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_pinned_location_to_users() TO service_role;

REVOKE EXECUTE ON FUNCTION public.trg_admin_broadcast_quick_dispatch() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trg_admin_broadcast_quick_dispatch() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_admin_broadcast_quick_dispatch() TO service_role;

REVOKE EXECUTE ON FUNCTION public.trg_notification_queue_ledger() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trg_notification_queue_ledger() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_notification_queue_ledger() TO service_role;

REVOKE EXECUTE ON FUNCTION public.trg_notification_queue_quick_dispatch() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trg_notification_queue_quick_dispatch() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_notification_queue_quick_dispatch() TO service_role;

REVOKE EXECUTE ON FUNCTION public.trg_notification_queue_to_inbox() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trg_notification_queue_to_inbox() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_notification_queue_to_inbox() TO service_role;

REVOKE EXECUTE ON FUNCTION public.trg_user_notifications_dedupe() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trg_user_notifications_dedupe() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_user_notifications_dedupe() TO service_role;

REVOKE EXECUTE ON FUNCTION public.trigger_update_user_visibility() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trigger_update_user_visibility() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_update_user_visibility() TO service_role;

REVOKE EXECUTE ON FUNCTION public.unmatch_from_system_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unmatch_from_system_match(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unmatch_from_system_match(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.upload_offline_trail(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upload_offline_trail(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upload_offline_trail(jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.validate_promo_code(text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_promo_code(text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_promo_code(text, uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.verify_email_change_code(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(uuid, text) TO service_role;

-- PostgREST caches function privileges per role, and a bare GRANT/REVOKE does
-- not always raise the DDL event it listens for. Reload explicitly so the
-- API stops advertising the revoked RPCs immediately.
NOTIFY pgrst, 'reload schema';
