-- ============================================================================
-- Fix Admin Check Function
-- ============================================================================
-- This creates a SECURITY DEFINER function to check if a user is an admin
-- that bypasses RLS, avoiding circular dependency issues.
-- ============================================================================

BEGIN;

-- Drop existing function if it exists
DROP FUNCTION IF EXISTS public.is_admin_user(uuid);

-- Create a SECURITY DEFINER function that bypasses RLS
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

COMMIT;