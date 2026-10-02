-- Test the online count function with the current user ID
-- Replace 'dd6d20a5-cd79-4761-8a74-751acb555b4d' with your actual user ID if different

SELECT public.get_online_users_count('dd6d20a5-cd79-4761-8a74-751acb555b4d'::uuid) as online_count;

-- Also test without user ID (if function allows null)
-- SELECT public.get_online_users_count(NULL::uuid) as online_count;

-- Check the user's visibility setting in the users table
SELECT
    id,
    user_visibility_setting,
    system_visibility_status
FROM users
WHERE id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d';