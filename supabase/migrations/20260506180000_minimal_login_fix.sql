-- ============================================================================
-- Minimal Login Fix - Users Table Only
-- ============================================================================
-- This only fixes the users table circular dependency issue to allow login.
-- Other permission issues should be addressed separately via Supabase dashboard.
-- ============================================================================

BEGIN;

-- Create SECURITY DEFINER function to check admin status
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

-- Fix users table policy to use the function (avoids circular dependency)
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
USING (public.is_admin_user());

COMMIT;