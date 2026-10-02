-- Check what auth.uid() returns
SELECT auth.uid() as current_auth_uid;

-- Test with explicit user ID
SELECT public.is_admin_user('ffc20046-a777-463b-922a-547151aa1455') as is_admin_with_id;

-- Check if the function is SECURITY DEFINER (runs with elevated privileges)
SELECT prosrc FROM pg_proc WHERE proname = 'is_admin_user';