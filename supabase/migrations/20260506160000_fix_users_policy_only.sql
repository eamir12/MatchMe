-- ============================================================================
-- Fix Users Table Policy Only
-- ============================================================================
-- This only fixes the users table policy to resolve the login issue.
-- Other tables should already have appropriate policies.
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

-- Fix users table policy - use SECURITY DEFINER function to avoid circular dependency
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
USING (public.is_admin_user());

COMMIT;