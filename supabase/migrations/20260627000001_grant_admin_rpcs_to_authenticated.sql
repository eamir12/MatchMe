-- Grant EXECUTE on all admin_ functions to authenticated.
-- These were revoked by 20260506220000_security_cleanup_final.sql and
-- only granted to service_role, but the admin Flutter app authenticates
-- as a regular user whose is_admin flag is checked inside each function.
BEGIN;

DO $$
DECLARE
    func_record RECORD;
BEGIN
    FOR func_record IN
        SELECT DISTINCT
            p.proname AS function_name,
            pg_get_function_identity_arguments(p.oid) AS params
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
          AND p.prokind = 'f'
          AND p.proname LIKE 'admin\_%'
    LOOP
        BEGIN
            EXECUTE format(
                'GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated;',
                func_record.function_name,
                func_record.params
            );
        EXCEPTION WHEN others THEN
            RAISE WARNING 'Could not grant on %(%) — %',
                func_record.function_name, func_record.params, SQLERRM;
        END;
    END LOOP;
END $$;

COMMIT;
