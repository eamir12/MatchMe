-- Simplified permission fix - grant EXECUTE by function name only
-- This avoids signature mismatch issues

DO $$
DECLARE
    func_record RECORD;
BEGIN
    -- Grant EXECUTE on all app functions to authenticated
    FOR func_record IN
        SELECT
            p.proname as function_name,
            pg_get_function_arguments(p.oid) as arguments
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND p.proname IN (
            -- Chat/Messaging functions
            'mark_message_delivered',
            'mark_messages_as_read',
            'set_message_reaction',
            'edit_chat_message',
            'edit_message',
            'get_message_reactors',
            -- User/Profile functions
            'claim_referral',
            'update_user_activity',
            'health_check',
            'set_user_offline',
            'revoke_all_user_sessions',
            'unmatch_from_system_match',
            -- Matching/Rating functions
            'get_due_match_rating_prompts',
            'set_match_met_answer',
            'submit_match_rating',
            'get_user_rating_summary',
            'get_online_users_count',
            'get_online_users_count_excluding_self',
            'get_nearby_users_count',
            -- Event functions
            'count_event_attendees',
            -- Ad-related functions
            'get_sponsored_ad_for_placement',
            'record_ad_impression',
            'record_ad_click',
            -- Promo code functions
            'validate_promo_code',
            'redeem_promo_code',
            -- Email change functions
            'generate_email_change_code',
            'verify_email_change_code',
            -- Session functions
            'upsert_user_session',
            'get_user_recent_chats',
            'get_user_recent_matches'
        )
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I TO authenticated', func_record.function_name);
        RAISE NOTICE 'Granted EXECUTE on %', func_record.function_name;
    END LOOP;
END $$;

-- Grant SELECT on necessary tables
GRANT SELECT ON TABLE public.admin_broadcast_deliveries TO authenticated;
GRANT SELECT ON TABLE public.user_session TO authenticated;

-- Grant EXECUTE to anon for public functions
GRANT EXECUTE ON FUNCTION public.health_check() TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_online_users_count_excluding_self(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_nearby_users_count(uuid, integer) TO anon;

-- Verify key permissions
SELECT
    routine_name,
    privilege_type,
    grantee
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
    AND routine_name IN ('get_user_recent_chats', 'upsert_user_session', 'get_user_rating_summary', 'mark_message_delivered')
    AND privilege_type = 'EXECUTE'
    AND grantee = 'authenticated'
ORDER BY routine_name;