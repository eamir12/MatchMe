-- Restore a real table access check inside health_check().
-- The 20260506238000 revert dropped the PERFORM, so health_check only
-- proved the DB round-trip worked: broken tables / RLS / permissions /
-- a botched migration would still report ok=true. Re-add the probe
-- while keeping the jsonb {ok, checked_at, error} contract the admin
-- System Health monitor consumes.

CREATE OR REPLACE FUNCTION public.health_check()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM 1 FROM users LIMIT 1;
  RETURN jsonb_build_object('ok', true, 'checked_at', now());
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'checked_at', now());
END;
$$;

GRANT EXECUTE ON FUNCTION public.health_check() TO anon;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;
GRANT EXECUTE ON FUNCTION public.health_check() TO service_role;
