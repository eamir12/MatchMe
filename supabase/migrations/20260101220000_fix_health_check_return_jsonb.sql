-- Replace health_check to return JSONB to avoid client-side type errors
-- Idempotent: overwrites any prior definition

CREATE OR REPLACE FUNCTION public.health_check()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Lightweight check: attempt to read from users
  PERFORM 1 FROM users LIMIT 1;
  RETURN jsonb_build_object('ok', true, 'checked_at', now());
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'checked_at', now());
END;
$$;

GRANT EXECUTE ON FUNCTION public.health_check() TO anon;
GRANT EXECUTE ON FUNCTION public.health_check() TO authenticated;