BEGIN;

-- Function to cleanup old edge_function_invocations records (older than 7 days)
CREATE OR REPLACE FUNCTION public.cleanup_edge_function_invocations()
RETURNS TABLE (
  deleted_count int
) AS $$
DECLARE
  v_deleted_count int;
BEGIN
  DELETE FROM public.edge_function_invocations
  WHERE invoked_at < now() - interval '7 days';

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  RETURN QUERY SELECT v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
