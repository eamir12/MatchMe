-- ============================================================================
-- Check Authentication Context and Admin Status
-- ============================================================================

-- Check if your user has is_admin = true
SELECT id, email, is_admin FROM public.users WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Test the is_admin_user function with your specific user ID
SELECT public.is_admin_user('ffc20046-a777-463b-922a-547151aa1455') as is_admin_check_with_id;

-- Test what the is_admin_user function returns for the current auth.uid()
SELECT public.is_admin_user() as is_admin_check_current_auth;

-- Check what auth.uid() returns (if you're logged in)
SELECT auth.uid() as current_auth_uid;

-- Check the current policies on app_config
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