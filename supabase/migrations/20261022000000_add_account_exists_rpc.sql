-- Account-existence probe for the client session policy.
--
-- The app only signs a user out automatically when the account no longer
-- exists. GoTrue's `getUser()` can prove deletion only while the access token
-- is still accepted; an expired JWT is rejected before the account lookup, and
-- a refresh token is deleted together with the auth user. In that state the
-- client cannot distinguish "deleted account" from "revoked session".
--
-- This narrow RPC closes that gap. It reveals only whether the UUID the caller
-- already possesses exists in auth.users, and it is safe to expose to anon:
-- UUIDs are not enumerable, and a boolean is the only data returned.

CREATE OR REPLACE FUNCTION public.account_exists(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id = p_user_id
  );
$$;

REVOKE ALL ON FUNCTION public.account_exists(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.account_exists(UUID) TO anon, authenticated;
