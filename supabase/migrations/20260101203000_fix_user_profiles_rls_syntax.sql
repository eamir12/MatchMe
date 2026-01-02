-- Fix broken RLS policy created using "FOR INSERT, UPDATE" which is invalid syntax
-- This migration is idempotent: it drops the bad policy if present and creates correct INSERT/UPDATE policies.

DO $$
BEGIN
  -- Drop the incorrectly created combined policy if it exists
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'UserProfiles: owner upsert' AND tablename = 'user_profiles'
  ) THEN
    DROP POLICY "UserProfiles: owner upsert" ON public.user_profiles;
  END IF;
END;
$$;

-- Create a policy for INSERT with WITH CHECK
DROP POLICY IF EXISTS "UserProfiles: owner insert" ON public.user_profiles;
CREATE POLICY "UserProfiles: owner insert" ON public.user_profiles
  FOR INSERT
  WITH CHECK (auth.uid() = user_id OR auth.jwt() ->> 'role' = 'service_role');

-- Create a policy for UPDATE with USING + WITH CHECK
DROP POLICY IF EXISTS "UserProfiles: owner update" ON public.user_profiles;
CREATE POLICY "UserProfiles: owner update" ON public.user_profiles
  FOR UPDATE
  USING (auth.uid() = user_id OR auth.jwt() ->> 'role' = 'service_role')
  WITH CHECK (auth.uid() = user_id OR auth.jwt() ->> 'role' = 'service_role');

-- Ensure delete remains service-only
DROP POLICY IF EXISTS "UserProfiles: delete service only" ON public.user_profiles;
CREATE POLICY "UserProfiles: delete service only" ON public.user_profiles
  FOR DELETE
  USING (auth.jwt() ->> 'role' = 'service_role');

-- Ensure table has RLS enabled
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;