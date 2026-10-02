-- Grant EXECUTE on ALL public functions to authenticated (broad approach to fix cascading permissions)

DO $$
DECLARE
    func_record RECORD;
    grant_statement TEXT;
BEGIN
    -- Grant EXECUTE on ALL public functions to authenticated
    FOR func_record IN
        SELECT
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid) as arguments
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND p.prolang != 13  -- Exclude internal functions (language 13 is internal)
    LOOP
        grant_statement := format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated',
            func_record.function_name,
            func_record.arguments);
        BEGIN
            EXECUTE grant_statement;
            RAISE NOTICE 'Granted EXECUTE on %', func_record.function_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Skipped % (error: %)', func_record.function_name, SQLERRM;
        END;
    END LOOP;
END $$;

-- Grant SELECT on necessary tables
GRANT SELECT ON TABLE public.admin_broadcast_deliveries TO authenticated;
GRANT SELECT ON TABLE public.user_session TO authenticated;
GRANT SELECT ON TABLE public.admin_broadcasts TO authenticated;

-- Grant EXECUTE to anon for public read-only functions
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