-- Revoke all EXECUTE grants from authenticated to get back to clean state
-- Migration: 20260506220000_revoke_all_authenticated_grants

-- ============================================================================
-- Revoke EXECUTE from authenticated for ALL functions in public schema
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
        AND p.proname NOT IN (
            -- Keep admin functions as-is (they should only be accessible by service_role)
            'admin_update_promo_codes_config',
            'cleanup_expired_password_reset_tokens',
            'get_security_definer_functions_audit'
        )
    LOOP
        BEGIN
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I FROM authenticated', func_record.function_name);
        EXCEPTION WHEN others THEN
            CONTINUE;
        END;
    END LOOP;
END $$;