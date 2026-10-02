-- ============================================================================
-- Diagnostic Query for Admin Permissions
-- ============================================================================

-- Check the user's current is_admin status
SELECT id, email, is_admin FROM public.users WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Test the is_admin_user function directly
SELECT public.is_admin_user('ffc20046-a777-463b-922a-547151aa1455') as is_admin_check;

-- Check if RLS is enabled on app_config
SELECT relname, relrowsecurity 
FROM pg_class 
WHERE relname = 'app_config';

-- Check ALL policies on app_config (not just admin ones)
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

-- Check if there are any other policies that might be blocking
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
  AND policyname NOT LIKE 'Admins can%'
ORDER BY policyname;