-- ============================================================================
-- Dynamic Admin Permissions Setup
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: Create the is_admin_user function
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_admin_user(user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = user_id
      AND is_admin = true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_admin_user TO authenticated;

-- ============================================================================
-- STEP 2: Create RLS policies for all tables using a temp function
-- ============================================================================

CREATE OR REPLACE FUNCTION public.setup_admin_policies()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  v_tbl TEXT;
BEGIN
  FOR r IN
    SELECT table_name::text as tn FROM information_schema.tables 
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  LOOP
    v_tbl := r.tn;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_tbl);
    EXECUTE format('DROP POLICY IF EXISTS "Admins can read %I" ON public.%I', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY "Admins can read %I" ON public.%I FOR SELECT TO authenticated USING (public.is_admin_user())', v_tbl, v_tbl);
    EXECUTE format('DROP POLICY IF EXISTS "Admins can insert %I" ON public.%I', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY "Admins can insert %I" ON public.%I FOR INSERT TO authenticated WITH CHECK (public.is_admin_user())', v_tbl, v_tbl);
    EXECUTE format('DROP POLICY IF EXISTS "Admins can update %I" ON public.%I', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY "Admins can update %I" ON public.%I FOR UPDATE TO authenticated USING (public.is_admin_user())', v_tbl, v_tbl);
    EXECUTE format('DROP POLICY IF EXISTS "Admins can delete %I" ON public.%I', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY "Admins can delete %I" ON public.%I FOR DELETE TO authenticated USING (public.is_admin_user())', v_tbl, v_tbl);
    RAISE NOTICE 'Created policies for: %', v_tbl;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.setup_admin_policies TO authenticated;

SELECT public.setup_admin_policies();

DROP FUNCTION IF EXISTS public.setup_admin_policies();

-- ============================================================================
-- STEP 3: Grant execute on admin functions
-- ============================================================================

CREATE OR REPLACE FUNCTION public.grant_admin_function_permissions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args 
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'admin_%'
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', r.proname, r.args);
    RAISE NOTICE 'Granted: %', r.proname;
  END LOOP;
  FOR r IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args 
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'is_admin_user'
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', r.proname, r.args);
  END LOOP;
  FOR r IN 
    SELECT proname, pg_get_function_identity_arguments(oid) as args 
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('count_target_users', 'get_broadcast_stats')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s(%s) TO authenticated', r.proname, r.args);
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.grant_admin_function_permissions TO authenticated;

SELECT public.grant_admin_function_permissions();

DROP FUNCTION IF EXISTS public.grant_admin_function_permissions();

COMMIT;

-- Verification
SELECT 'Policies created:' as status, COUNT(*) as count FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'Admins can%';