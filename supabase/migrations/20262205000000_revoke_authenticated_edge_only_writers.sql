-- Migration: revoke authenticated EXECUTE on writers that only service_role calls.
-- Date: 2026-10-29
--
-- S1 (20262201000000) revoked anon/PUBLIC on every SECURITY DEFINER function and
-- granted authenticated + service_role. That left 306 SECURITY DEFINER functions
-- executable by any signed-in account, including the maintenance writers below
-- that no client calls.
--
-- Method: the ACL state was read from production, then every SECURITY DEFINER
-- function was matched against the call sites in this repository:
--   * Flutter app   lib/**               135 literal .rpc() names, plus the three
--                                        dynamic sites (claim_onboarding_core_tour,
--                                        meetup_* via _rpc(), the offline queue's
--                                        set_chat_translation/mark_messages_as_read)
--                                        and the raw /rest/v1/rpc/ URLs.
--   * Admin app     matchme_admin/**
--   * Edge functions supabase/functions/** and the deployed-only functions fetched
--                    from the Management API (contextual-match, match-engine*,
--                    approve-primary-photo, *-email-change-otp, ...).
-- The role an edge function's RPC runs as is decided by the Authorization header,
-- not by the key: creating a client with the service key and forwarding the
-- caller's JWT still executes as authenticated. Every function below was confirmed
-- to be called on a client with no Authorization override, i.e. as service_role.
-- SQL callers, trigger usage and policy usage were checked in production.
--
-- The 16 functions below are called only by cron-jobs, push-message,
-- compare-verification-photos and the shared edge helpers (all service_role), and
-- two of them additionally by SECURITY DEFINER triggers, which run as the owner.
--
-- Deliberately NOT included:
--   generate_email_change_code, verify_email_change_code, complete_email_change
--     sensitive-action-email-code builds its client with the caller's JWT, so
--     these execute as authenticated by design.
--   approve_primary_photo
--     the deployed approve-primary-photo function forwards the caller's JWT.
--   admin_get_health_errors, get_notification_queue_health
--     both are called by matchme_admin with the signed-in admin's JWT.
--
-- Blast radius: EXECUTE grants only. No body, owner, volatility or search_path
-- changes. service_role and the owner keep EXECUTE; pg_cron runs as postgres.
-- Rollback: grant execute on function <signature> to authenticated;  (per function)
--
-- Verification (run after applying):
--   select p.proname,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
--          has_function_privilege('service_role',  p.oid, 'EXECUTE') as svc_exec
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public'
--     and p.proname in (
--       'cleanup_expired_offline_trail','cleanup_old_user_locations',
--       'cleanup_pending_email_changes','cleanup_stale_online_users',
--       'clear_user_session_fcm_token','clear_user_session_wns_channel',
--       'consume_ai_rate_limit','edge_update_verification',
--       'expire_pinned_locations','get_masked_sender_name',
--       'log_edge_function_invocation','perform_continuous_user_matching',
--       'prune_admin_health_snapshots','scheduled_subscription_normalization',
--       'touch_active_pinned_locations','upsert_currency_exchange_rates_batch')
--   order by 1;
--   -- expect auth_exec = false and svc_exec = true on all 16 rows.

revoke execute on function public.cleanup_expired_offline_trail() from public, authenticated;
revoke execute on function public.cleanup_old_user_locations(p_minutes_old integer) from public, authenticated;
revoke execute on function public.cleanup_pending_email_changes() from public, authenticated;
revoke execute on function public.cleanup_stale_online_users() from public, authenticated;
revoke execute on function public.clear_user_session_fcm_token(p_fcm_token text) from public, authenticated;
revoke execute on function public.clear_user_session_wns_channel(p_wns_channel_uri text) from public, authenticated;
revoke execute on function public.consume_ai_rate_limit(p_identifier text, p_task text, p_hourly_limit integer, p_daily_limit integer) from public, authenticated;
revoke execute on function public.edge_update_verification(p_user_id uuid, p_patch jsonb) from public, authenticated;
revoke execute on function public.expire_pinned_locations() from public, authenticated;
revoke execute on function public.get_masked_sender_name(p_sender_id uuid) from public, authenticated;
revoke execute on function public.log_edge_function_invocation(p_request_id uuid, p_function_name text, p_duration_ms integer, p_success boolean, p_http_status integer, p_error_type text, p_error_message text, p_user_id uuid, p_ai_used boolean, p_ai_provider text, p_ai_model text, p_ai_task text, p_meta jsonb) from public, authenticated;
revoke execute on function public.perform_continuous_user_matching() from public, authenticated;
revoke execute on function public.prune_admin_health_snapshots() from public, authenticated;
revoke execute on function public.scheduled_subscription_normalization() from public, authenticated;
revoke execute on function public.touch_active_pinned_locations() from public, authenticated;
revoke execute on function public.upsert_currency_exchange_rates_batch(p_base_currency text, p_rates jsonb, p_source text, p_fetched_at timestamp with time zone) from public, authenticated;

do $$
declare
  fn text;
  fns text[] := array[
    'public.cleanup_expired_offline_trail()',
    'public.cleanup_old_user_locations(integer)',
    'public.cleanup_pending_email_changes()',
    'public.cleanup_stale_online_users()',
    'public.clear_user_session_fcm_token(text)',
    'public.clear_user_session_wns_channel(text)',
    'public.consume_ai_rate_limit(text,text,integer,integer)',
    'public.edge_update_verification(uuid,jsonb)',
    'public.expire_pinned_locations()',
    'public.get_masked_sender_name(uuid)',
    'public.log_edge_function_invocation(uuid,text,integer,boolean,integer,text,text,uuid,boolean,text,text,text,jsonb)',
    'public.perform_continuous_user_matching()',
    'public.prune_admin_health_snapshots()',
    'public.scheduled_subscription_normalization()',
    'public.touch_active_pinned_locations()',
    'public.upsert_currency_exchange_rates_batch(text,jsonb,text,timestamp with time zone)'
  ];
begin
  foreach fn in array fns loop
    if has_function_privilege('authenticated', fn::regprocedure, 'EXECUTE') then
      raise exception 'authenticated still has EXECUTE on %', fn;
    end if;
    if not has_function_privilege('service_role', fn::regprocedure, 'EXECUTE') then
      raise exception 'service_role lost EXECUTE on %', fn;
    end if;
    if not has_function_privilege(current_user, fn::regprocedure, 'EXECUTE') then
      raise exception 'owner lost EXECUTE on %', fn;
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
