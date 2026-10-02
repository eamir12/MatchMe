-- ============================================================================
-- Fix admin permissions - direct grants and verify function
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: Recreate is_admin_user function with proper error handling
-- ============================================================================

-- Use CREATE OR REPLACE to avoid dropping dependent policies

CREATE OR REPLACE FUNCTION public.is_admin_user(user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.users
    WHERE id = user_id AND is_admin = true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_admin_user TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin_user TO anon;

-- ============================================================================
-- STEP 2: Direct table grants (bypass RLS for authenticated users)
-- ============================================================================

-- Grant full access to all tables for authenticated role
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOR tbl IN SELECT table_name::text FROM information_schema.tables 
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('GRANT ALL ON TABLE public.%I TO authenticated', tbl);
  END LOOP;
END $$;

-- Grant usage on all sequences
DO $$
DECLARE
  seq TEXT;
BEGIN
  FOR seq IN SELECT sequence_name::text FROM information_schema.sequences
    WHERE sequence_schema = 'public'
  LOOP
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO authenticated', seq);
  END LOOP;
END $$;

COMMIT;

-- ============================================================================
-- STEP 3: Verify
-- ============================================================================

-- Test the function
SELECT public.is_admin_user() as is_admin_check;

-- Show what policies exist
SELECT tablename, policyname FROM pg_policies 
WHERE schemaname = 'public' AND policyname LIKE '%admin%'
LIMIT 20;