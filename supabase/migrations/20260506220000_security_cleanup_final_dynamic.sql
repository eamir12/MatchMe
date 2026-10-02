-- Dynamic script to grant EXECUTE to authenticated for app functions
-- This script checks which functions actually exist before granting
-- Migration: 20260506220000_security_cleanup_final_dynamic

-- ============================================================================
-- Step 1: Revoke EXECUTE from authenticated for ALL functions
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
-- Step 2: Grant EXECUTE to service_role for admin functions
-- ============================================================================

DO $$
BEGIN
    -- Try to grant to admin functions, ignore if they don't exist
    BEGIN
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) TO service_role';
    EXCEPTION WHEN others THEN NULL;
    END;
    
    BEGIN
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.cleanup_expired_password_reset_tokens() TO service_role';
    EXCEPTION WHEN others THEN NULL;
    END;
    
    BEGIN
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_security_definer_functions_audit() TO service_role';
    EXCEPTION WHEN others THEN NULL;
    END;
END $$;

-- ============================================================================
-- Step 3: Grant EXECUTE to authenticated for app functions
-- Uses dynamic lookup to find actual function signatures
-- ============================================================================

DO $$
DECLARE
    func_record RECORD;
    func_signature text;
BEGIN
    -- Get all functions with their actual signatures
    FOR func_record IN 
        SELECT 
            p.proname as function_name,
            pg_get_function_arguments(p.oid) as arguments
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND p.proname IN (
            -- Subscription functions
            'add_subscription_to_queue',
            'get_next_queued_subscription',
            'cancel_queued_subscription',
            'trigger_subscription_normalization',
            'check_and_normalize_user_subscription',
            'get_subscription_cron_status',
            'apply_revenuecat_subscription',
            -- Chat/Messaging functions
            'mark_message_delivered',
            'mark_messages_as_read',
            'set_message_reaction',
            'edit_chat_message',
            'edit_message',
            'get_message_reactors',
            'block_user',
            'report_user',
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
            'get_nearby_users_count',
            -- Event functions
            'count_event_attendees',
            -- Ad-related functions
            'get_sponsored_ad_for_placement',
            'get_external_ad_for_placement',
            'record_ad_impression',
            'record_ad_click',
            'record_ad_revenue',
            'record_external_ad_impression',
            'record_external_ad_click',
            'user_can_receive_ads',
            -- Promo code functions
            'validate_promo_code',
            'redeem_promo_code',
            'get_promo_code_details',
            -- Email change functions
            'generate_email_change_code',
            'verify_email_change_code',
            'complete_email_change'
        )
    LOOP
        BEGIN
            func_signature := 'public.' || func_record.function_name || '(' || func_record.arguments || ')';
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', func_signature);
        EXCEPTION WHEN others THEN
            CONTINUE;
        END;
    END LOOP;
END $$;