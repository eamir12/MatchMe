-- Comprehensive permission fix for all app functions and tables
-- This grants EXECUTE on all RPC functions the Flutter app needs

-- ============================================================================
-- Grant EXECUTE on all app RPC functions to authenticated
-- ============================================================================

-- Chat/Messaging functions
GRANT EXECUTE ON FUNCTION public.mark_message_delivered(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_message_reaction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_message_reactors(uuid, text) TO authenticated;

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
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO authenticated;

-- Event functions
GRANT EXECUTE ON FUNCTION public.count_event_attendees(uuid) TO authenticated;

-- Ad-related functions
GRANT EXECUTE ON FUNCTION public.get_sponsored_ad_for_placement(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_impression(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_ad_click(uuid, text, text) TO authenticated;

-- Promo code functions
GRANT EXECUTE ON FUNCTION public.validate_promo_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(text) TO authenticated;

-- Email change functions
GRANT EXECUTE ON FUNCTION public.generate_email_change_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_email_change_code(text, text) TO authenticated;

-- Session functions
GRANT EXECUTE ON FUNCTION public.upsert_user_session(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_chats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_recent_matches(uuid) TO authenticated;

-- ============================================================================
-- Grant SELECT on necessary tables
-- ============================================================================

GRANT SELECT ON TABLE public.admin_broadcast_deliveries TO authenticated;
GRANT SELECT ON TABLE public.user_session TO authenticated;

-- ============================================================================
-- Grant EXECUTE to anon for public functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.health_check() TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO anon;

-- ============================================================================
-- Verify key permissions
-- ============================================================================

SELECT
    routine_name,
    privilege_type,
    grantee
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
    AND routine_name IN ('get_user_recent_chats', 'upsert_user_session', 'get_user_rating_summary')
    AND privilege_type = 'EXECUTE'
    AND grantee = 'authenticated'
ORDER BY routine_name;