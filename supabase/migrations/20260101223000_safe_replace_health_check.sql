-- Safely replace public.health_check() to return JSONB
-- Idempotent: drops old function only if it exists and its return type is NOT jsonb

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN pg_type t ON p.prorettype = t.oid
    WHERE p.proname = 'health_check' AND n.nspname = 'public' AND t.typname <> 'jsonb'
  ) THEN
    RAISE NOTICE 'Dropping legacy health_check() with non-jsonb return type';
    DROP FUNCTION public.health_check();
  END IF;
END;
$$;

-- Create the JSONB-returning health_check (idempotent because of CREATE OR REPLACE)
CREATE OR REPLACE FUNCTION public.health_check()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
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