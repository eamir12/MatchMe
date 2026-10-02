-- Check user is_admin status
SELECT id, email, is_admin FROM public.users WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Also test is_admin_user function
SELECT public.is_admin_user('ffc20046-a777-463b-922a-547151aa1455') as is_admin_check;