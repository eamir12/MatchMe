-- Fix user online status functions
-- Grant EXECUTE to authenticated for all user presence/activity functions
-- Migration: 20260506230000_fix_user_online_status_functions

-- ============================================================================
-- Check and grant EXECUTE for user online status functions
-- ============================================================================

DO $$
DECLARE
    func_record RECORD;
BEGIN
    -- Get all user presence/activity related functions
    FOR func_record IN 
        SELECT 
            p.proname as function_name,
            pg_get_function_arguments(p.oid) as arguments
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND p.proname IN (
            'update_user_activity',
            'set_user_offline',
            'set_user_online',
            'is_user_online',
            'is_user_online_realtime',
            'is_user_truly_visible',
            'is_user_truly_visible_realtime',
            'user_presence_join',
            'user_presence_leave',
            'broadcast_user_online_event',
            'detect_and_broadcast_offline_users',
            'set_user_visibility',
            'trigger_update_user_visibility'
        )
    LOOP
        BEGIN
            -- Grant EXECUTE to authenticated
            EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated', 
                         func_record.function_name, 
                         func_record.arguments);
            
            -- Also grant to anon for public presence if needed
            EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO anon', 
                         func_record.function_name, 
                         func_record.arguments);
        EXCEPTION WHEN others THEN
            -- Log the error but continue
            RAISE NOTICE 'Failed to grant EXECUTE for %: %', 
                          func_record.function_name, SQLERRM;
        END;
    END LOOP;
END $$;

-- ============================================================================
-- Verify permissions for key functions
-- ============================================================================

SELECT 
    routine_name,
    privilege_type,
    grantee
FROM information_schema.role_routine_grants
WHERE routine_schema = 'public'
AND routine_name IN (
    'update_user_activity',
    'set_user_offline',
    'is_user_online'
)
ORDER BY routine_name, grantee;