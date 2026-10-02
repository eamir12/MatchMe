-- Grant EXECUTE to authenticated for all public functions except admin functions
-- This is a safer approach that doesn't require knowing exact function signatures
-- Migration: 20260506210000_grant_app_functions_smart

-- ============================================================================
-- Step 1: Grant EXECUTE to authenticated for ALL functions in public schema
-- ============================================================================

DO $$
DECLARE
    func_record RECORD;
BEGIN
    FOR func_record IN 
        SELECT 
            p.proname as function_name,
            pg_get_function_arguments(p.oid) as arguments
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND p.proname NOT IN (
            -- Admin functions to exclude
            'admin_update_promo_codes_config',
            'cleanup_expired_password_reset_tokens',
            'get_security_definer_functions_audit'
        )
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated', 
                     func_record.function_name, 
                     func_record.arguments);
    END LOOP;
END $$;

-- ============================================================================
-- Step 2: Ensure admin functions are revoked from authenticated
-- ============================================================================

REVOKE ALL ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) FROM authenticated;
REVOKE ALL ON FUNCTION public.cleanup_expired_password_reset_tokens() FROM authenticated;
REVOKE ALL ON FUNCTION public.get_security_definer_functions_audit() FROM authenticated;

-- ============================================================================
-- Step 3: Grant EXECUTE to service_role for admin functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_password_reset_tokens() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_security_definer_functions_audit() TO service_role;

-- ============================================================================
-- Summary
-- ============================================================================
-- This script:
-- 1. Grants EXECUTE to authenticated for ALL public functions except the 3 admin functions
-- 2. Ensures admin functions are revoked from authenticated
-- 3. Grants EXECUTE to service_role for admin functions
--
-- This approach is safer because it:
-- - Doesn't require knowing exact function signatures
-- - Automatically handles all functions your app uses
-- - Keeps admin functions secure