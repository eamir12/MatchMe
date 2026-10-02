-- Migration: Add RPC function to cleanup old user locations for privacy
-- Created: 2026-05-05

-- Function to delete user locations older than specified minutes (for privacy)
CREATE OR REPLACE FUNCTION public.cleanup_old_user_locations(p_minutes_old int DEFAULT 15)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted int := 0;
  v_cutoff timestamptz;
BEGIN
  v_cutoff := now() - (p_minutes_old || ' minutes')::interval;
  
  DELETE FROM public.user_locations
  WHERE updated_at < v_cutoff;
  
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  
  RETURN v_deleted;
END;
$$;

-- Grant execute to service role (used by edge functions)
GRANT EXECUTE ON FUNCTION public.cleanup_old_user_locations(int) TO service_role;

-- Grant execute to authenticated users (if needed for admin purposes)
GRANT EXECUTE ON FUNCTION public.cleanup_old_user_locations(int) TO authenticated;
