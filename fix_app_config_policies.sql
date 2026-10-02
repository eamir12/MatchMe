-- ============================================================================
-- Fix Conflicting app_config Policies
-- ============================================================================

BEGIN;

-- Drop the conflicting overly-permissive policies
DROP POLICY IF EXISTS "Authenticated users can update app_config" ON public.app_config;
DROP POLICY IF EXISTS "Authenticated users can read app_config" ON public.app_config;

-- Drop the redundant "Anyone can read" policy (admin policies are more specific)
DROP POLICY IF EXISTS "Anyone can read app_config" ON public.app_config;

-- Ensure RLS is enabled
ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Create clean admin-only policies
DROP POLICY IF EXISTS "Admins can read app_config" ON public.app_config;
CREATE POLICY "Admins can read app_config" ON public.app_config
FOR SELECT
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can update app_config" ON public.app_config;
CREATE POLICY "Admins can update app_config" ON public.app_config
FOR UPDATE
TO authenticated
USING (public.is_admin_user());

DROP POLICY IF EXISTS "Admins can insert app_config" ON public.app_config;
CREATE POLICY "Admins can insert app_config" ON public.app_config
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin_user());

COMMIT;

-- Verify the fix
SELECT 
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'app_config'
ORDER BY policyname;