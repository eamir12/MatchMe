-- Migration: Add RPC function for cleanup of old profile_edit_requests
-- Called by cron-jobs edge function
-- Keeps: last 30 days of completed requests, all pending requests

CREATE OR REPLACE FUNCTION public.cleanup_old_profile_edit_requests()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM public.profile_edit_requests
  WHERE status IN ('approved', 'rejected')
    AND created_at < now() - interval '30 days';
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_old_profile_edit_requests() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_old_profile_edit_requests() TO service_role;

COMMIT;
