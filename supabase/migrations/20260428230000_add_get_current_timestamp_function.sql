-- Add get_current_timestamp function for connectivity checks
-- This is a simple function that returns the current database timestamp
-- Used by admin_sync_manager to verify database connectivity

CREATE OR REPLACE FUNCTION public.get_current_timestamp()
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT now();
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION public.get_current_timestamp() TO authenticated;

-- Grant execute permission to service role
GRANT EXECUTE ON FUNCTION public.get_current_timestamp() TO service_role;

COMMENT ON FUNCTION public.get_current_timestamp() IS 
    'Returns the current database timestamp for connectivity checks';
