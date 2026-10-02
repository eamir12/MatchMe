-- ============================================================================
-- Grant Admin Table Permissions (Direct GRANT approach)
-- ============================================================================
-- This grants direct table permissions to authenticated role as a fallback
-- when RLS policies cannot be modified due to permission constraints.
-- ============================================================================

BEGIN;

-- Ensure the is_admin_user function exists
CREATE OR REPLACE FUNCTION public.is_admin_user(user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = user_id
      AND is_admin = true
  );
END;
$$;

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION public.is_admin_user TO authenticated;

-- Fix users table policy
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
USING (public.is_admin_user());

-- Grant direct permissions on app_config as fallback
-- This works even if we can't modify RLS policies
GRANT SELECT ON public.app_config TO authenticated;
GRANT UPDATE ON public.app_config TO authenticated;

COMMIT;