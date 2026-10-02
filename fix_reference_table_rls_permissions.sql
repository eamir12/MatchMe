-- ============================================================================
-- Fix RLS / table-level permissions for reference (lookup) tables
--
-- Problem:
--   Several reference tables lost table-level SELECT grants for anon and/or
--   authenticated roles due to revoke migrations 20260506170000 and
--   20260506183000. The app reads these directly via .from('...').select()
--   and would get 401/42501 errors.
--
-- Principle (least privilege):
--   - app_languages / translations: needed BEFORE auth (login screen
--     language picker + localized UI) → GRANT to anon + authenticated
--   - app_gender_options, currency_exchange_rates, intents, interests:
--     needed only AFTER auth → GRANT to authenticated only
-- ============================================================================

BEGIN;

-- =========================================================
-- 1. Table-level GRANTs (conditional on table existence)
-- =========================================================

-- Public bootstrap tables — needed before auth
DO $$
DECLARE
  v_tables text[] := ARRAY['app_languages', 'translations'];
  v_t record;
BEGIN
  FOR v_t IN
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY(v_tables)
    ORDER BY c.relname
  LOOP
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO anon, authenticated', v_t.table_name);
  END LOOP;
END
$$;

-- Post-auth only tables
DO $$
DECLARE
  v_tables text[] := ARRAY[
    'app_gender_options',
    'currency_exchange_rates',
    'intents',
    'interests'
  ];
  v_t record;
BEGIN
  FOR v_t IN
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY(v_tables)
    ORDER BY c.relname
  LOOP
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated', v_t.table_name);
  END LOOP;
END
$$;

-- =========================================================
-- 2. RLS policies
-- =========================================================

-- Public bootstrap — policy applies to both roles
DO $$
DECLARE
  v_tables text[] := ARRAY['app_languages', 'translations'];
  v_t record;
BEGIN
  FOR v_t IN
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY(v_tables)
    ORDER BY c.relname
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "Public read access" ON public.%I', v_t.table_name);
    EXECUTE format(
      'CREATE POLICY "Public read access" ON public.%I FOR SELECT TO anon, authenticated USING (true)',
      v_t.table_name
    );
  END LOOP;
END
$$;

-- Post-auth only — policy applies only to authenticated
DO $$
DECLARE
  v_tables text[] := ARRAY[
    'app_gender_options',
    'currency_exchange_rates',
    'intents',
    'interests'
  ];
  v_t record;
BEGIN
  FOR v_t IN
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY(v_tables)
    ORDER BY c.relname
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "Authenticated read access" ON public.%I', v_t.table_name);
    EXECUTE format(
      'CREATE POLICY "Authenticated read access" ON public.%I FOR SELECT TO authenticated USING (true)',
      v_t.table_name
    );
  END LOOP;
END
$$;

-- =========================================================
-- 3. Verify the fix
-- =========================================================

DO $$
DECLARE
  v_tables text[] := ARRAY[
    'app_languages',
    'translations',
    'app_gender_options',
    'currency_exchange_rates',
    'intents',
    'interests'
  ];
  v_t record;
BEGIN
  RAISE NOTICE '=== Table-level grants check ===';
  FOR v_t IN
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY(v_tables)
    ORDER BY c.relname
  LOOP
    RAISE NOTICE '  %: anon=%  authenticated=%',
      v_t.table_name,
      has_table_privilege('anon', format('public.%I', v_t.table_name), 'SELECT'),
      has_table_privilege('authenticated', format('public.%I', v_t.table_name), 'SELECT');
  END LOOP;

  RAISE NOTICE '=== RLS policies check ===';
  FOR v_t IN
    SELECT tablename, policyname, roles
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = ANY(v_tables)
    ORDER BY tablename, policyname
  LOOP
    RAISE NOTICE '  %.%  roles=%', v_t.tablename, v_t.policyname, v_t.roles;
  END LOOP;
END
$$;

COMMIT;
