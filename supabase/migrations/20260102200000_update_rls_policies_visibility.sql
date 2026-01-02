-- Update RLS policies to respect the new visibility predicate
-- Run after renaming migration and function creation

-- Example: Prevent public/anon role from selecting invisible users
-- Be careful and test in staging before applying to production

-- Revoke any existing permissive SELECT policy that exposes visible info
REVOKE ALL ON users FROM anon;

-- Ensure row-level security is enabled for users table
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Create a safe SELECT policy for anon that only returns truly visible users (guarded)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'anon_select_truly_visible') THEN
    CREATE POLICY anon_select_truly_visible ON public.users
      FOR SELECT
      TO anon
      USING (public.is_user_truly_visible(id) = TRUE);
  END IF;
END$$;

-- If you have policies allowing certain columns, ensure they don't leak full names
-- For example, prevent anon from seeing `user_profiles.profile_data->>'fullName'` (it's safer to expose masked name via an RPC)

-- Grant necessary exec privileges to helper functions
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;
GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO anon;

-- NOTE: Adjust policies for authenticated role as per product rules
-- For signed-in users, you might allow some additional columns, but still ensure that full names are never exposed and use mask_full_name for any returned names

-- Test the policy with sample queries in a staging environment
-- e.g. SELECT id, public.is_user_truly_visible(id) FROM users; -- should reflect intended behavior
