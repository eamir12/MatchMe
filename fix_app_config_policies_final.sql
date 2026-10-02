-- ============================================================================
-- Fix app_config Policies - Use Direct SQL Check
-- ============================================================================

BEGIN;

-- Drop ALL existing policies on app_config
DROP POLICY IF EXISTS "Admins can insert app_config" ON public.app_config;
DROP POLICY IF EXISTS "Admins can read app_config" ON public.app_config;
DROP POLICY IF EXISTS "Admins can update app_config" ON public.app_config;
DROP POLICY IF EXISTS "Only admins can delete app_config" ON public.app_config;
DROP POLICY IF EXISTS "Only admins can insert app_config" ON public.app_config;
DROP POLICY IF EXISTS "Only admins can update app_config" ON public.app_config;

-- Ensure RLS is enabled
ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Create policies using direct SQL check (more reliable than function)
CREATE POLICY "Admins can read app_config" ON public.app_config
FOR SELECT
TO authenticated
USING (EXISTS (
  SELECT 1 FROM users 
  WHERE id = auth.uid() AND is_admin = true
));

CREATE POLICY "Admins can update app_config" ON public.app_config
FOR UPDATE
TO authenticated
USING (EXISTS (
  SELECT 1 FROM users 
  WHERE id = auth.uid() AND is_admin = true
));

CREATE POLICY "Admins can insert app_config" ON public.app_config
FOR INSERT
TO authenticated
WITH CHECK (EXISTS (
  SELECT 1 FROM users 
  WHERE id = auth.uid() AND is_admin = true
));

COMMIT;

-- Verify the fix
SELECT 
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'app_config'
ORDER BY policyname;