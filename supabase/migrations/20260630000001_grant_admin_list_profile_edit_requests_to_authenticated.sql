-- Re-grant EXECUTE on admin_list_profile_edit_requests to authenticated
-- The function already has an is_admin check inside, so only admin users can use it.
-- This is needed by the admin Flutter app which uses the anon key + user JWT.
-- (Migration 20260506202000 revoked this from authenticated; this restores it.)

GRANT EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) TO authenticated;

COMMIT;
