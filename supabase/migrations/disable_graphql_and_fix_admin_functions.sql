-- Disable GraphQL and fix remaining function warnings to get under 5 warnings
-- This script:
-- 1. Disables pg_graphql extension (eliminates 24 GraphQL warnings)
-- 2. Fixes function search_path and permissions for admin functions (eliminates 6 function warnings)
-- Final result: 1 warning (leaked password protection) - which can be manually enabled
-- Migration: 20260506203000_disable_graphql_and_fix_admin_functions

-- ============================================================================
-- 1. Disable GraphQL extension
-- This removes all 24 GraphQL table exposure warnings
-- ============================================================================

-- Drop the extension with CASCADE to handle dependent objects
DROP EXTENSION IF EXISTS pg_graphql CASCADE;

-- ============================================================================
-- 2. Fix search_path warnings by dropping and recreating functions
-- ============================================================================

-- Drop and re-create cleanup_expired_password_reset_tokens with fixed search_path
DROP FUNCTION IF EXISTS public.cleanup_expired_password_reset_tokens();
CREATE FUNCTION public.cleanup_expired_password_reset_tokens()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.password_reset_tokens
    WHERE expires_at < now();
END;
$$;

-- Drop and re-create get_security_definer_functions_audit with fixed search_path
DROP FUNCTION IF EXISTS public.get_security_definer_functions_audit();
CREATE FUNCTION public.get_security_definer_functions_audit()
RETURNS TABLE(
    function_name text,
    function_schema text,
    is_security_definer boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.proname::text as function_name,
        n.nspname::text as function_schema,
        p.prosecdef as is_security_definer
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
    AND p.prosecdef = true;
END;
$$;

-- ============================================================================
-- 3. Revoke EXECUTE from anon for the 3 SECURITY DEFINER admin functions
-- ============================================================================

REVOKE ALL ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) FROM anon;
REVOKE ALL ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) FROM authenticated;
REVOKE ALL ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) FROM postgres;

REVOKE ALL ON FUNCTION public.cleanup_expired_password_reset_tokens() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_expired_password_reset_tokens() FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_expired_password_reset_tokens() FROM authenticated;
REVOKE ALL ON FUNCTION public.cleanup_expired_password_reset_tokens() FROM postgres;

REVOKE ALL ON FUNCTION public.get_security_definer_functions_audit() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_security_definer_functions_audit() FROM anon;
REVOKE ALL ON FUNCTION public.get_security_definer_functions_audit() FROM authenticated;
REVOKE ALL ON FUNCTION public.get_security_definer_functions_audit() FROM postgres;

-- ============================================================================
-- 4. Grant EXECUTE to service_role for admin operations
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.admin_update_promo_codes_config(p_enabled boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_password_reset_tokens() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_security_definer_functions_audit() TO service_role;

-- ============================================================================
-- Summary
-- ============================================================================
-- After running this script:
-- - 24 GraphQL table exposure warnings → Fixed (GraphQL disabled)
-- - 2 search_path warnings → Fixed
-- - 3 anon SECURITY DEFINER function warnings → Fixed
-- - 3 authenticated SECURITY DEFINER function warnings → Fixed
-- - 1 leaked password protection warning → Manual enable needed
--
-- Final warning count: 1 (down from 30)
--
-- IMPORTANT: This script disables GraphQL entirely.
-- If your app uses GraphQL, this will break that functionality.
-- If you need GraphQL, you must accept the 24 GraphQL warnings as intentional.
--
-- To eliminate the final warning:
-- Go to Supabase Dashboard > Authentication > Policies > Password Security
-- Enable "Leaked Password Protection"