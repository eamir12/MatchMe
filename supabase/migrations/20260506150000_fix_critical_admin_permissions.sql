-- ============================================================================
-- Fix Critical Admin Permissions (Minimal Version)
-- ============================================================================
-- This fixes only the critical issues without modifying existing policies
-- on tables that may already have proper access controls.
-- ============================================================================

BEGIN;

-- Ensure the is_admin_user function exists (in case the previous migration failed)
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

-- Grant execute to authenticated users (if not already granted)
GRANT EXECUTE ON FUNCTION public.is_admin_user TO authenticated;

-- Only update policies on tables that are known to be problematic
-- users table - critical for login
DROP POLICY IF EXISTS "Admins can read users" ON public.users;
CREATE POLICY "Admins can read users" ON public.users
FOR SELECT
USING (public.is_admin_user());

COMMIT;