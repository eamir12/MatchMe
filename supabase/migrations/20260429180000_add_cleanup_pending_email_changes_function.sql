BEGIN;

-- Create function to cleanup expired pending email changes
-- This runs as SECURITY DEFINER to bypass RLS policies
CREATE OR REPLACE FUNCTION public.cleanup_pending_email_changes()
RETURNS TABLE (
  deleted_count bigint
) AS $$
DECLARE
  v_deleted_count bigint;
BEGIN
  -- Delete expired pending email changes (where expires_at < now)
  DELETE FROM public.pending_email_changes
  WHERE expires_at < now();

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  RETURN QUERY SELECT v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission to service role
GRANT EXECUTE ON FUNCTION public.cleanup_pending_email_changes() TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_pending_email_changes() TO postgres;

COMMIT;
