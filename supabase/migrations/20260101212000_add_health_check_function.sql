-- Add a lightweight health check RPC for Supabase client initialization
-- This function is SECURITY DEFINER and grants execution to anon/authenticated so web clients can perform a safe health check without needing direct table access.

DROP FUNCTION IF EXISTS public.health_check();

CREATE OR REPLACE FUNCTION public.health_check()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Lightweight check: try to read a single row from users without returning data
  PERFORM 1 FROM users LIMIT 1;
  RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
  -- If any error occurs (permissions, connectivity), return false for the check
  RETURN FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.health_check() TO anon;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;